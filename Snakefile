#!/usr/bin/env python3

container: "docker://continuumio/miniconda3:4.7.12"

import os
import random
import tempfile
from set_config import set_config, read_paths, nBeads, adjustCoordinates

BASE = workflow.basedir

# Define path to conda environment specifications
ENVS = f'{BASE}/workflow/envs'
# Defne path to custom scripts directory
SCRIPTS = f'{BASE}/workflow/scripts'

if not config:
    configfile: f'{BASE}/config/config.yaml'

# Defaults configuration file - use empty string to represent no default value.
# Note does not currently correctly deal with special case config['masking'] in set_config
default_config = {
    'workdir':        workflow.basedir,
    'ctcf':           None,
    'masking':        {},
    'genome' :        {'build':    'genome',
                       'sequence':  None,
                       'name':      None,
                       'genes':     None,
                       'chr':       None,
                       'start':     None,
                       'end':       None,},
    'maxProb':        0.9,
    'syntheticSequence' : {}              ,
    'bases_per_bead': 1000,
    'monomers':       100,
    'method':         'mean',
    'coeffs':         '',
    'reps':           5,
    'random':         {'seed':             42,
                       'walk':             False,
                       'sequence':         True ,
                       'initialConform':   True ,
                       'monomerPositions': True,
                       'simulation':       True ,},
    'box':            {'xlo':        -50,
                       'xhi':         50,
                       'ylo':        -50,
                       'yhi':         50,
                       'zlo':        -50,
                       'zhi':         50,},
    'lammps':         {'restart':        0      ,
                       'timestep':       1000   ,
                       'softWarmUp':     20000  ,
                       'harmonicWarmUp': 20000  ,
                       'simTime':        2000000,
                       'ctcfSteps':      100    ,
                       'TFswap':         10000  ,},
    'HiC':            {'matrix' :    None    ,
                       'binsize':    None    ,
                       'log' :       True    ,
                       'colourMap': 'Purples',
                       'dpi':        300     ,
                       'vMin':       None    ,
                       'vMax':       None    ,
                       'vMin2':      None    ,
                       'vMax2':      None    ,},
    'plotRG':         {'dpi':        300     ,
                       'confidence': 0.95    ,},
    'plotTU':         {'pvalue':     0.1     ,
                       'vMin':      -0.3     ,
                       'vMax':       0.3     ,
                       'minRep':     1       ,
                       'fontSize':   14      ,},
    'GIF':            {'create':     True    ,
                       'delay':      10      ,
                       'loop':       0       ,},
    'groupJobs':      False,
    'cluster':        False,
}
config = set_config(config, default_config)

workdir : config['workdir']

details = {}
if not config['syntheticSequence']:
    # If no synthetic sequence ensure genome information is provided.
    invalid = False
    for key in ['sequence', 'name', 'chr', 'start', 'end']:
        if config['genome'][key] is None:
            sys.stderr.write(
                f'\033[31mNo synthetic sequence provided and '
                f'config["genome"]["{key}"] not set.\033[m\n')
            invalid = True
    if invalid:
        sys.exit('\033[31mInvalid configuration setting.\033[m\n')
    for name in [config['genome']['name']]:
        start, end = adjustCoordinates(
            config['genome']['start'],
            config['genome']['end'],
            config['bases_per_bead'])
        scaledRegion = f"{config['genome']['chr']}-{start}-{end}"
        print(f'Adjusting {name} positions to {scaledRegion}')
        details[name] = {'chr':   config['genome']['chr'],
                         'start': start, 'end': end}
else:
    config['genome']['sequence'] = []
    for name in config['syntheticSequence'].keys():
        end = (nBeads(config['syntheticSequence'][name])
               * config['bases_per_bead'])
        details[name] = {'chr':   name,
                         'start': 1,
                         'end':   end}

BUILD = config['genome']['build']

# Define list of N reps from 1 to N
REPS = list(range(1, config['reps'] + 1))

# Set seeds for different parts of workflow.
seeds = {}
for type in ['sequence', 'initialConform', 'monomerPositions', 'simulation']:
    random.seed(config['random']['seed'])
    if config['random'][type]:
        seeds[type] = [random.randint(1, (2**16) - 1) for rep in REPS]
    else:
        seeds[type] = [random.randint(1, (2**16) - 1)] * config['reps']

if config['HiC']['binsize'] is not None:
    BINSIZE = int(config['HiC']['binsize'])
    MERGEBINS, REMAINDER = divmod(BINSIZE, config['bases_per_bead'])
    if REMAINDER:
        sys.exit(
            f'\033[31Binsize {config["HiC"]["binsize"]} is not divisible by '
            f'bases per bead {config["bases_per_bead"]}.\033[m\n')
else:
    MERGEBINS = 1
    BINSIZE = config['bases_per_bead']


# Read track file basename and masking character into a dictionary
track_data = {}
if config['masking']:
    for file, character in config['masking'].items():
        track_file = f'{os.path.basename(file)}'
        track_data[track_file] = {'source' : file, 'character' : character}

wildcard_constraints:
    all = r'[^\/]+',
    stat = r'stats|pairStats',
    name = rf'{"|".join(details.keys())}',
    binsize = rf'{BINSIZE}',
    nbases = rf'{config["bases_per_bead"]}',
    rep = rf'{"|".join([str(rep) for rep in REPS])}'


rule all:
    input:
        [expand('vmd/{name}-{nbases}-1-simulation.gif',
            nbases=config['bases_per_bead'],
            name=details.keys()) if config['GIF']['create'] else [],
         expand('plots/contactMatrix/{name}-{nbases}-{binsize}-contactMatrix.png',
            nbases=config['bases_per_bead'], name=details.keys(), binsize=BINSIZE),
         expand('plots/{plot}/{name}-{nbases}-{plot}.png',
            nbases=config['bases_per_bead'], name=details.keys(),
            plot=['pairCluster', 'meanVariance','TUcorrelation', 'TUcircos',
                  'radiusGyration', 'TUreplicateCount',]),
         expand('{name}/{nbases}/merged/{name}-TU-{stat}.csv.gz',
            name=details.keys(), nbases=config['bases_per_bead'],
            stat=['stats', 'pairStats'])]


rule unzipGenome:
    input:
        config['genome']['sequence']
    output:
        temp(f'genome/{BUILD}.fa')
    log:
        f'logs/unzipGenome/{BUILD}.log'
    shell:
        'zcat -f {input} > {output} 2> {log}'


rule indexGenome:
    input:
        rules.unzipGenome.output
    output:
        f'{rules.unzipGenome.output}.fai'
    log:
        f'logs/indexGenome/{BUILD}.log'
    conda:
        f'{ENVS}/samtools.yaml'
    shell:
        'samtools faidx {input} &> {log}'


rule getChromSizes:
    input:
        rules.indexGenome.output
    output:
        f'genome/{BUILD}-chrom.sizes'
    log:
        f'logs/getChromSizes/{BUILD}.log'
    shell:
        'cut -f 1,2 {input} > {output} 2> {log}'


if config['ctcf'] is not None:

    rule filterCTCF:
        input:
            config['ctcf']
        output:
            'tracks/{rep}/CTCF/CTCF-filtered.bed'
        params:
            rep = REPS,
            maxProb = config['maxProb'],
            seed = lambda wc: seeds['sequence'][int(wc.rep) - 1]
        group:
            'lammps'
        log:
            'logs/sampleBed/{rep}.log'
        conda:
            f'{ENVS}/python3.yaml'
        shell:
            '{SCRIPTS}/filterBedScore.py --seed {params.seed} '
            '--maxProb {params.maxProb} {input} > {output} 2> {log}'


    rule splitOrientation:
        input:
            rules.filterCTCF.output
        output:
            forward = 'tracks/{rep}/CTCF/CTCF-filtered-forward.bed',
            reversed = 'tracks/{rep}/CTCF/CTCF-filtered-reverse.bed'
        group:
            'lammps'
        log:
            'logs/splitOrientation/{rep}.log'
        conda:
            f'{ENVS}/python3.yaml'
        shell:
            '{SCRIPTS}/splitOrientation.py '
            '--forward {output.forward} --reverse {output.reversed} '
            '{input} &> {log}'


rule filterTracks:
    input:
        lambda wc: track_data[wc.track]['source']
    output:
        'tracks/{rep}/other/{track}'
    params:
        rep = REPS,
        maxProb = config['maxProb'],
        seed = lambda wc: seeds['sequence'][int(wc.rep) - 1]
    group:
        'lammps'
    log:
        'logs/filterTracks/{track}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/filterBedScore.py --seed {params.seed} '
        '--maxProb {params.maxProb} {input} > {output} 2> {log}'


def getRegion(wc):
    chrom = details[wc.name]['chr']
    start = details[wc.name]['start']
    end = details[wc.name]['end']
    return f'{chrom}:{start}-{end}'


def getMasking(wc):
    """ Build masking command for maskFasta for track data """
    command = ''
    for track in track_data:
        character = track_data[track]['character']
        command += f'--bed tracks/{wc.rep}/other/{track},{character} '
    if config['ctcf'] is not None:
        command += (f'--bed tracks/{wc.rep}/CTCF/CTCF-filtered-forward.bed,F '
                    f'--bed tracks/{wc.rep}/CTCF/CTCF-filtered-reverse.bed,R ')
    return command


def getSplitOrient(wc):
    """ Return rule output only if used. """
    if config['ctcf'] is not None:
        return rules.splitOrientation.output
    else:
        return []


rule maskFasta:
    input:
        getSplitOrient,
        expand('tracks/{{rep}}/other/{track}', track=track_data.keys()),
        chromSizes = rules.getChromSizes.output
    output:
        '{name}/reps/{name}-{rep}-masked.fa'
    params:
        masking = getMasking,
        region = getRegion,
        seed = lambda wc: seeds['sequence'][int(wc.rep) - 1]
    group:
        'lammps'
    log:
        'logs/maskFasta/maskFasta-{name}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/maskFasta.py {input.chromSizes} {params.masking} '
        '--region {params.region} --seed {params.seed} > {output} 2> {log}'


rule FastaToBeads:
    input:
        rules.maskFasta.output
    output:
        '{name}/{nbases}/reps/{rep}/{name}-beads-{rep}.txt'
    group:
        'lammps'
    params:
        bases_per_bead = config['bases_per_bead'],
        seed = lambda wc: seeds['sequence'][int(wc.rep) - 1]
    log:
        'logs/sequenceToBeads/{name}-{nbases}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/FastaToBeads.py --nbases {params.bases_per_bead} '
        '--seed {params.seed} {input} > {output} 2> {log}'


rule sampleSynthetic:
    input:
        lambda wc: config['syntheticSequence'][wc.name]
    output:
        '{name}/{nbases}/reps/{rep}/sampledSynthetic-{rep}.txt'
    params:
        seed = lambda wc: seeds['sequence'][int(wc.rep) - 1],
    log:
        'logs/sampleSynthetic/{name}-{nbases}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        'python {SCRIPTS}/sampleSynthetic.py {input} --seed {params.seed} '
        '> {output} 2> {log}'


def beadsInput(wc):
    if config['syntheticSequence']:
        return rules.sampleSynthetic.output
    else:
        return rules.FastaToBeads.output


def setBeadsToLammpsCmd():
    cmd = '{SCRIPTS}/generate_polymer.py '
    cmd += (
        '--polymerSeed {params.polymerSeed} '
        '--monomerSeed {params.monomerSeed} '
        '--xlo {params.xlo} --xhi {params.xhi} '
        '--ylo {params.ylo} --yhi {params.yhi} '
        '--zlo {params.zlo} --zhi {params.zhi} '
        '--ctcf --coeffOut {output.coeffs} '
        '--groupOut {output.groups} '
        '--nMonomer {params.nMonomers} '
        '--pairCoeffs {params.coeffs} '
        '--basesPerBead {params.basesPerBead} '
        '{params.randomWalk} {input.beads} > {output.dat} 2> {log}')
    return cmd


rule BeadsToLammps:
    input:
        beads = beadsInput,
    output:
        dat = '{name}/{nbases}/reps/{rep}/lammps/config/lammps_input.dat',
        coeffs = '{name}/{nbases}/reps/{rep}/lammps/config/coeffs.txt',
        groups = '{name}/{nbases}/reps/{rep}/lammps/config/groups.txt'
    params:
        nMonomers = config['monomers'],
        coeffs = config['coeffs'],
        basesPerBead = config['bases_per_bead'],
        polymerSeed = lambda wc: seeds['initialConform'][int(wc.rep) - 1],
        monomerSeed = lambda wc: seeds['monomerPositions'][int(wc.rep) - 1],
        xlo = config['box']['xlo'],
        xhi = config['box']['xhi'],
        ylo = config['box']['ylo'],
        yhi = config['box']['yhi'],
        zlo = config['box']['zlo'],
        zhi = config['box']['zhi'],
        randomWalk = '--randomWalk' if config['random']['walk'] else ''
    group:
        'lammps'
    log:
        'logs/BeadsToLammps/{name}-{nbases}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        setBeadsToLammpsCmd()


rule writeLammps:
    input:
        script = f'{SCRIPTS}/run.lam',
        dat = rules.BeadsToLammps.output.dat,
        groups = rules.BeadsToLammps.output.groups,
        coeffs = rules.BeadsToLammps.output.coeffs,
    output:
        '{name}/{nbases}/reps/{rep}/lammps/config/run.lam'
    params:
        TFswap = config['lammps']['TFswap'],
        timestep = config['lammps']['timestep'],
        ctcfSteps = config['lammps']['ctcfSteps'],
        seed = lambda wc: seeds['simulation'][int(wc.rep) - 1],
        cosinePotential = lambda wc: 10000 / config['bases_per_bead'],
        simTime = config['lammps']['simTime'],
        sim = '{name}/{nbases}/reps/{rep}/lammps/simulation.custom.gz',
        softWarmUp = config['lammps']['softWarmUp'],
        harmonicWarmUp = config['lammps']['harmonicWarmUp'],
        warmUp = '{name}/{nbases}/reps/{rep}/lammps/warmUp.custom.gz',
        restartStep = int(config['lammps']['restart']),
        restartPrefix = '{name}/{nbases}/reps/{rep}/lammps/restart/Restart',
        radiusGyration = '{name}/{nbases}/reps/{rep}/lammps/radius_of_gyration.txt'
    group:
        'lammps'
    log:
        'logs/writeLammps/{name}-{nbases}-{rep}.log'
    shell:
        '{SCRIPTS}/writeLammps.py --dat {input.dat} --groups {input.groups} '
        '--pairCoeff {input.coeffs} --timestep {params.timestep} '
        '--softWarmUp {params.softWarmUp} '
        '--harmonicWarmUp {params.harmonicWarmUp} --warmUpOut {params.warmUp} '
        '--simOut {params.sim} --simTime {params.simTime} '
        '--cosinePotential {params.cosinePotential}  '
        '--radiusGyrationOut {params.radiusGyration} --seed {params.seed} '
        '--restartPrefix {params.restartPrefix} '
        '--restartStep {params.restartStep} --TFswap {params.TFswap} '
        '--ctcfSteps {params.ctcfSteps} {input.script} > {output} 2> {log}'


lmp_cmd = '-in {input} -log /dev/null &> {log}'
if config['cluster'] and not config['groupJobs']:
    lmp_cmd = 'mpirun -np {threads} lmp_mpi ' + lmp_cmd
else:
    lmp_cmd = 'lmp_serial ' + lmp_cmd

def setRestart():
    """ Include restart directory if included """
    if config['lammps']['restart']:
        return directory('{name}/{nbases}/reps/{rep}/lammps/restart/')
    else:
        return []

rule lammps:
    input:
        rules.writeLammps.output
    output:
        warmUp = '{name}/{nbases}/reps/{rep}/lammps/warmUp.custom.gz',
        simulation = '{name}/{nbases}/reps/{rep}/lammps/simulation.custom.gz',
        radiusGyration = '{name}/{nbases}/reps/{rep}/lammps/radius_of_gyration.txt',
        restart = setRestart()
    group:
        'lammps'
    log:
        'logs/lammps/{name}-{nbases}-{rep}.log'
    conda:
        f'{ENVS}/lammps.yaml'
    shell:
        lmp_cmd


rule plotRG:
    input:
        expand('{{name}}/{{nbases}}/reps/{rep}/lammps/radius_of_gyration.txt',
            rep=REPS)
    output:
        'plots/radiusGyration/{name}-{nbases}-radiusGyration.png'
    params:
        confidence = config['plotRG']['confidence'],
        dpi = config['plotRG']['dpi']
    group:
        'lammps' if config['groupJobs'] else 'plotRG'
    log:
        'logs/plotRG/{name}-{nbases}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/plotRG.py --out {output} --dpi {params.dpi} '
        '--confidence {params.confidence} {input} 2> {log}'


rule getAtomGroups:
    input:
        rules.BeadsToLammps.output.dat
    output:
        '{name}/{nbases}/reps/{rep}/lammps/config/atomGroups.json'
    group:
        'processAllLammps' if config['groupJobs'] else 'getAtomGroups'
    log:
        'logs/getAtomGroups/{name}-{nbases}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/getAtomGroups.py {input} > {output} 2> {log}'


rule writeTUdistribution:
    input:
        expand('{{name}}/{{nbases}}/reps/{rep}/lammps/config/atomGroups.json', rep=REPS)
    output:
        '{name}/{nbases}/merged/info/{name}-TU-distribution.csv.gz'
    group:
        'processAllLammps' if config['groupJobs'] else 'writeTUdistribution'
    log:
        'logs/writeTUdistribution/{name}-{nbases}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/writeTUdistribution.py --out {output} {input} &> {log}'


rule reformatLammps:
    input:
        rules.lammps.output.simulation
    output:
        '{name}/{nbases}/reps/{rep}/lammps/simulation.csv.gz'
    group:
        'processAllLammps' if config['groupJobs'] else 'reformatLammps'
    log:
        'logs/reformatLammps/{name}-{nbases}-{rep}.log'
    shell:
        '({SCRIPTS}/reformatLammps.awk <(zcat {input}) | gzip > {output}) &> {log}'


rule processTUinfo:
    input:
        sim = rules.reformatLammps.output,
        groups = rules.getAtomGroups.output
    output:
        '{name}/{nbases}/reps/{rep}/TU-info.csv.gz',
    params:
        distance = 1.8
    group:
        'processAllLammps' if config['groupJobs'] else 'processTUinfo'
    log:
        'logs/processTUinfo/{name}-{nbases}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/processTUinfo.py --out {output} '
        '--distance {params.distance} {input.groups} {input.sim} &> {log}'


rule DBSCAN:
    input:
        rules.processTUinfo.output
    output:
        clusterPairs = '{name}/{nbases}/reps/{rep}/TU-clusterPair.csv.gz',
        clusterPlot = 'plots/DBSCAN/{name}/{name}-{nbases}-{rep}-cluster.png',
    params:
        eps = 6,
        minSamples = 2
    group:
        'DBSCAN_all' if config['groupJobs'] else 'DBSCAN'
    log:
        'logs/DBSCAN/{name}-{nbases}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/dbscanTU.py --outplot {output.clusterPlot} '
        '--eps {params.eps} --minSamples {params.minSamples} '
        '--out {output.clusterPairs} {input} &> {log}'


rule plotDBSCAN:
    input:
        expand('{{name}}/{{nbases}}/reps/{rep}/TU-clusterPair.csv.gz', rep=REPS),
    output:
         'plots/pairCluster/{name}-{nbases}-pairCluster.png'
    group:
        'DBSCAN_all' if config['groupJobs'] else 'plotDBSCAN'
    log:
        'logs/plotDBSCAN/{name}-{nbases}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/plotDBSCAN.py {output} {input} &> {log}'


rule extractTADboundaries:
    input:
        rules.BeadsToLammps.output.dat
    output:
        '{name}/{nbases}/reps/{rep}/beadTADstatus.json',
    group:
        'processAllLammps' if config['groupJobs'] else 'processTUinfo'
    log:
        'logs/extractTADboundaries/{name}-{nbases}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        'python {SCRIPTS}/extractTADboundaries.py {input} > {output} 2> {log}'


rule computeTUstats:
    input:
        TUinfo = '{name}/{nbases}/reps/{rep}/TU-info.csv.gz',
        TADboundaries = rules.extractTADboundaries.output
    output:
        TUstats = '{name}/{nbases}/reps/{rep}/TU-stats.csv.gz',
        TUpairStats = '{name}/{nbases}/reps/{rep}/TU-pairStats.csv.gz',
    group:
        'processAllLammps' if config['groupJobs'] else 'computeTUstats'
    log:
        'logs/computeTUstats/{name}-{nbases}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/computeTUstats.py --out {output.TUstats} '
        '--TUpairStats {output.TUpairStats} '
        '--TADboundaries {input.TADboundaries} {input.TUinfo} &> {log}'


rule mergeByRep:
    input:
        expand('{{name}}/{{nbases}}/reps/{rep}/TU-{{stat}}.csv.gz', rep=REPS),
    output:
        '{name}/{nbases}/merged/{name}-TU-{stat}.csv.gz'
    group:
        'processAllLammps' if config['groupJobs'] else 'mergeByRep'
    log:
        'logs/mergeByRep/{name}-{nbases}-{stat}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/mergeByRep.py --out {output} {input} &> {log}'


rule plotMeanVariance:
    input:
        '{name}/{nbases}/merged/{name}-TU-stats.csv.gz'
    output:
        'plots/meanVariance/{name}-{nbases}-meanVariance.png'
    params:
        fontSize = config['plotTU']['fontSize']
    group:
        'processAllLammps' if config['groupJobs'] else 'plotMeanVariance'
    log:
        'logs/plotMeanVariance/{name}-{nbases}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/plotMeanVariance.py {input} --out {output} '
        '--fontSize {params.fontSize}  &> {log}'


rule computeTUcorrelation:
    input:
        rules.mergeByRep.output
    output:
        '{name}/{nbases}/merged/{name}-TU-correlation.csv.gz'
    group:
        'processAllLammps' if config['groupJobs'] else 'computeTUcorrelation'
    log:
        'logs/computeTUcorrelation/{name}-{nbases}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/computeTUcorrelation.py --out {output} {input} &> {log}'


rule plotTUcorrelation:
    input:
        correlations = rules.computeTUcorrelation.output,
        beadDistribution = rules.writeTUdistribution.output
    output:
        meanHeatmap = 'plots/TUcorrelation/{name}-{nbases}-TUcorrelation.png',
        sumHeatmap = 'plots/TUreplicateCount/{name}-{nbases}-TUreplicateCount.png',
        circos = 'plots/TUcircos/{name}-{nbases}-TUcircos.png'
    params:
        pvalue = config['plotTU']['pvalue'],
        vMin = config['plotTU']['vMin'],
        vMax = config['plotTU']['vMax'],
        minRep = config['plotTU']['minRep'],
        fontSize = config['plotTU']['fontSize']
    group:
        'processAllLammps' if config['groupJobs'] else 'plotTUcorrelation'
    log:
        'logs/plotTUcorrelation/{name}-{nbases}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/plotTUcorrelation.py {input.beadDistribution} '
        '{input.correlations} --circos {output.circos} '
        '--sumHeatmap {output.sumHeatmap} --meanHeatmap {output.meanHeatmap} '
        '--fontSize {params.fontSize} --pvalue {params.pvalue} '
        '--minRep {params.minRep} --vmin {params.vMin} '
        '--vmax {params.vMax} &> {log}'


rule createContactMatrix:
    input:
        xyz = rules.reformatLammps.output,
        groups = rules.getAtomGroups.output
    output:
        '{name}/{nbases}/reps/{rep}/matrices/contacts.npz'
    params:
        distance = 3,
        periodic = '--periodic',
        seed = lambda wc: seeds['simulation'][int(wc.rep) - 1],
        x = abs(config['box']['xhi'] - config['box']['xlo']),
        y = abs(config['box']['yhi'] - config['box']['ylo']),
        z = abs(config['box']['zhi'] - config['box']['zlo'])
    group:
        'processAllLammps' if config['groupJobs'] else 'createContactMatrix'
    log:
        'logs/createContactMatrix/{name}-{nbases}-{rep}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/createContactMatrix.py {params.periodic} '
        '--out {output} --distance {params.distance} --seed {params.seed} '
        '--dimensions {params.x} {params.y} {params.z} {input.groups} '
        '<(zcat -f {input.xyz}) &> {log}'


rule mergeReplicates:
    input:
        expand('{{name}}/{{nbases}}/reps/{rep}/matrices/contacts.npz',
            rep=REPS)
    output:
        '{name}/{nbases}/merged/matrices/{name}.npz'
    params:
        method = config['method']
    group:
        'processAllLammps' if config['groupJobs'] else 'createContactMatrix'
    log:
        'logs/mergeReplicates/{name}-{nbases}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/mergeMatrices.py --out {output} '
        '--method {params.method} {input} &> {log}'


rule matrix2homer:
    input:
        '{name}/{nbases}/merged/matrices/{name}.npz'
    output:
        '{name}/{nbases}/merged/matrices/{name}.homer'
    params:
        chr = lambda wc: details[wc.name]['chr'],
        start = lambda wc: details[wc.name]['start'],
        binsize = config['bases_per_bead']
    log:
        'logs/matrix2homer/{name}-{nbases}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/npz2homer.py --chromosome {params.chr} '
        '--start {params.start} --binsize {params.binsize} '
        '{input} > {output} 2> {log}'


rule homer2H5:
    input:
        rules.matrix2homer.output
    output:
        '{name}/{nbases}/merged/matrices/{name}.h5'
    log:
        'logs/homer2H5/{name}-{nbases}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    threads:
        workflow.cores
    shell:
        'hicConvertFormat --matrices {input} --outFileName {output} '
        '--inputFormat homer --outputFormat h5 &> {log}'


rule mergeBins:
    input:
        rules.homer2H5.output
    output:
        '{name}/{nbases}/merged/matrices/{name}-{binsize}.h5'
    params:
        nbins = MERGEBINS
    log:
        'logs/mergeBins/{name}-{nbases}-{binsize}.log'
    conda:
        f'{ENVS}/hicexplorer.yaml'
    shell:
        'hicMergeMatrixBins --matrix {input} --numBins {params.nbins} '
        '--outFileName {output} &> {log}'


def getHiCconfig(wc):
    """ Build config command for configuration """
    command = ''
    if not config['syntheticSequence']:
        if config['HiC']['matrix']:
            command += f'--flip --matrix2 {config["HiC"]["matrix"]} '
            if config['HiC']['vMin2']:
                command += f' --vMin2 {config["HiC"]["vMin2"]} '
            if config['HiC']['vMax2']:
                command += f' --vMax2 {config["HiC"]["vMax2"]} '
        if config['genome']['genes']:
            command += f' --genes {config["genome"]["genes"]} '
        if config['ctcf'] is not None:
            command += f'--ctcfOrient {config["ctcf"]} '
    if config['HiC']['vMin']:
        command += f' --vMin {config["HiC"]["vMin"]} '
    if config['HiC']['vMax']:
        command += f' --vMax {config["HiC"]["vMax"]} '
    if config['HiC']['log']:
        command += ' --logMatrix1 --logMatrix2 '

    command += f'--colourMap {config["HiC"]["colourMap"]}'
    return command


def getCTCFOrient(wc):
    """ Return CTCF orientation if not synthetic """
    if config['syntheticSequence'] is None:
        return config["ctcf"]
    else:
        return []

def getDepth(wc):
    return details[wc.name]['end'] - details[wc.name]['start'] + 1


rule createConfig:
    input:
        matrix = rules.mergeBins.output,
        ctcfOrient = getCTCFOrient
    output:
        '{name}/{nbases}/merged/config/{name}-{binsize}-configs.ini'
    params:
        depth = getDepth,
        hicConfig = getHiCconfig,
    group:
        'plotHiC'
    log:
        'logs/createConfig/{name}-{nbases}-{binsize}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '{SCRIPTS}/generate_config.py --matrix {input.matrix} '
        '--depth {params.depth} {params.hicConfig} > {output} 2> {log}'


def getTitle(wc):
    return f'"{wc.name} : {getRegion(wc)}"'


rule plotHiC:
    input:
        rules.createConfig.output
    output:
        'plots/contactMatrix/{name}-{nbases}-{binsize}-contactMatrix.png'
    params:
        region = getRegion,
        title = getTitle,
        dpi = config['HiC']['dpi']
    group:
        'plotHiC'
    log:
        'logs/plotHiC/{name}-{nbases}-{binsize}.log'
    conda:
        f'{ENVS}/pygenometracks.yaml'
    shell:
        'pyGenomeTracks --tracks {input} '
        '--region {params.region} '
        '--outFileName {output} '
        '--title {params.title} '
        '--dpi {params.dpi} &> {log}'


if config['syntheticSequence'] is None:

    rule matrix2pre:
        input:
            rules.mergeReplicates.output
        output:
            '{name}/{nbases}/merged/matrices/contacts.pre.tsv'
        params:
            chr = lambda wc: details[wc.name]['chr'],
            start = lambda wc: details[wc.name]['start'],
            binsize = config['bases_per_bead']
        log:
            'logs/matrix2pre/{name}-{nbases}.log'
        conda:
            f'{ENVS}/python3.yaml'
        shell:
            '{SCRIPTS}/npz2pre.py --chromosome {params.chr} '
            '--start {params.start} --binsize {params.binsize} '
            '{input} > {output} 2> {log}'


    rule juicerPre:
        input:
            tsv = rules.matrix2pre.output,
            chrom_sizes = rules.getChromSizes.output
        output:
            '{name}/{nbases}/merged/matrices/contacts.hic'
        log:
            'logs/juicerPre/{name}-{nbases}.log'
        params:
            chr = lambda wc: details[wc.name]['chr'],
            resolutions = '1000'
        resources:
             mem_mb = 16000
        threads:
            workflow.cores
        conda:
            f'{ENVS}/openjdk.yaml'
        shell:
            'java -Xmx{resources.mem_mb}m '
            '-jar {SCRIPTS}/juicer_tools_1.14.08.jar pre '
            '-c {params.chr} -r {params.resolutions} '
            '{input.tsv} {output} {input.chrom_sizes} &> {log}'


rule custom2XYZ:
    input:
        '{name}/{nbases}/reps/{rep}/lammps/{mode}.custom.gz'
    output:
        temp('{name}/{nbases}/reps/{rep}/lammps/{mode}.xyz.gz')
    group:
        'vmd'
    log:
        'logs/custom2XYZ/{name}-{nbases}-{rep}-{mode}.log'
    conda:
        f'{ENVS}/python3.yaml'
    shell:
        '(zcat {input} | {SCRIPTS}/custom2XYZ.py | gzip > {output}) 2> {log}'


checkpoint vmd:
    input:
        '{name}/{nbases}/reps/1/lammps/simulation.xyz.gz'
    output:
        directory('{name}/{nbases}/vmd/sequence')
    group:
        'vmd'
    log:
        'logs/vmd/{name}-{nbases}.log'
    conda:
        f'{ENVS}/vmd.yaml'
    shell:
        'vmd -eofexit -nt -dispdev text -args <(zcat {input}) {output} '
        '< {SCRIPTS}/vmd.tcl &> {log}'


def aggregateVMD(wildcards):
    """ Return all RGB files generated by vmd checkpoint. """

    dir = checkpoints.vmd.get(**wildcards).output[0]
    images = expand('{dir}/{i}.tga',
           i=glob_wildcards(os.path.join(dir, '{i}.tga')).i,
           dir=dir)
    return sorted(images)


rule createGIF:
    input:
        rules.vmd.output,
        images = aggregateVMD
    output:
        'vmd/{name}-{nbases}-1-simulation.gif'
    params:
        delay = config['GIF']['delay'],
        loop = config['GIF']['loop']
    group:
        'vmd'
    log:
        'logs/createGIF/{name}-{nbases}.log'
    conda:
        f'{ENVS}/imagemagick.yaml'
    shell:
        'convert -delay {params.delay} -loop {params.loop} '
        '{input.images} {output} &> {log}'
