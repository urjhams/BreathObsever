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
downsampled_smoothed_envelope = resample(samples, 100)

# Find power spectral density using Welch periodogram
frequencies, psd = welch(downsampled_smoothed_envelope, fs=10, nperseg=len(downsampled_smoothed_envelope))

for index in range(0, len(frequencies) - 1):
    print(f'{frequencies[index]} - {psd[index]}')

peak = findPeakIndex(psd)

# the highest peak represent the respiratory rate
respiratoryRateFrequency = frequencies[peak]

command = f'echo {respiratoryRateFrequency}'

os.system(command)
