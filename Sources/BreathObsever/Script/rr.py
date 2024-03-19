import os
import sys
from scipy.signal import resample, hilbert, butter, filtfilt, welch
import numpy as np

def findPeakIndex(array):
    peakIndex = 0
    currentPeak = -1
    for index in range(0, len(array) - 1):
        if array[index] > currentPeak:
            currentPeak = array[index]
            peakIndex = index
    return peakIndex

samples = sys.argv[1].split(',')

## Downsample to 20 Hz
downSampled = resample(samples, 100)

# Find power spectral density using Welch periodogram
# Note that we use the frequency at 10 Hz while the data represented as 20 Hz
# to get the higher resolution of result.
frequencies, psd = welch(downSampled, fs=10, nperseg=len(downSampled))

peak = findPeakIndex(psd)

# the highest peak represent the respiratory rate
respiratoryRateFrequency = frequencies[peak]

command = f'echo {respiratoryRateFrequency}'

os.system(command)
