#!/usr/bin/env python3

""" Average contact frequency matrices and plot heatmap """

import sys
import numpy as np
from typing import List
from utilities import npz
import pyCommonTools as pct
from scipy.sparse import save_npz, load_npz, csc_matrix

def main():

    __version__ = '1.0.0'

    parser = pct.make_parser(verbose=True, version=__version__)
    parser.set_defaults(function=average_heatmap)

    parser.add_argument(
        'matrices', nargs='+',
        help='Input contact matrices')
    parser.add_argument(
        '-o', '--out', default='averaged-contacts.npz', type=npz,
        help='Summed contact matrix (default: %(default)s)')
    parser.add_argument(
        '--method', default='sum', choices=['mean', 'median', 'sum'],
        help='Method to compute average of matrices (default: %(default)s)')

    return (pct.execute(parser))


def compute_median(matrices: List):
    # Stack matrices along a third dimension and compute median
    matrices = np.dstack([load_npz(matrix).toarray() for matrix in matrices])
    return csc_matrix(np.median(matrices, axis = 2))


def compute_sum(matrices: List):
    summed_matrix = 0
    for matrix in matrices:
        summed_matrix += load_npz(matrix)
    return summed_matrix


def compute_mean(matrices: List):
    summed_matrix = compute_sum(matrices)
    return summed_matrix / len(matrices)


def average_heatmap(matrices: List, out: str, method: str) -> None:

    if method == 'median':
        average_matrix = compute_median(matrices)
    elif method == 'sum':
        average_matrix = compute_sum(matrices)
    else:
        average_matrix = compute_mean(matrices)

    save_npz(out, average_matrix)


if __name__ == '__main__':
    sys.exit(main())