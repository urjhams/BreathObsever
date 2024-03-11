import os
import sys
from scipy.signal import resample, hilbert, butter, filtfilt, welch
import numpy as np

def arrays_to_txt(originalSamples, envelope, file_path):
    try:
        with open(file_path, 'w') as file:
            sampleStr = "["
            for item in originalSamples:
                sampleStr += f'{item},'
            sampleStr += "]"

            envelopeStr = "["
            for item in envelope:
                envelopeStr += f'{item},'
            envelopeStr += "]"

            file.write(f'{sampleStr}\n')
            file.write(f'{envelopeStr}\n')
        print("Arrays have been successfully written to", file_path)
    except IOError:
        print("Error: Unable to write to file", file_path)

def findPeakIndex(array):
    peakIndex = 0
    currentPeak = -1
    for index in range(0, len(array) - 1):
        if array[index] > currentPeak:
            currentPeak = array[index]
            peakIndex = index
    return index

samples = sys.argv[1].split(',')

fs = 24000  # Sampling frequency
t = np.arange(0, 5, 1/fs)  # Time vector
samples = np.sin(2 * np.pi * 1000 * t)  # Example sinusoidal signal

# Downsample to 1000 Hz
downsampled_samples = resample(samples, int(len(samples) * (1000 / fs)))

# Extract the signal envelope using Hilbert transform
envelope = np.abs(hilbert(downsampled_samples))

# Apply a low pass filter (2 Hz) to the envelope
nyquist_freq = 1000 / 2  # Nyquist frequency for 1000 Hz
cutoff_freq = 2  # Cutoff frequency for the low-pass filter
b, a = butter(4, cutoff_freq / nyquist_freq, btype='low')
filtered_envelope = filtfilt(b, a, envelope)

# Smooth the signal by Hanning moving window
smoothed_envelope = np.convolve(filtered_envelope, np.hanning(50), mode='same')

# Downsample to 10 Hz
downsampled_smoothed_envelope = resample(smoothed_envelope, int(len(smoothed_envelope) * (10 / 1000)))

# Find power spectral density using Welch periodogram
frequencies, psd = welch(downsampled_smoothed_envelope, fs=10, nperseg=50)

arrays_to_txt(samples, downsampled_smoothed_envelope, '/Users/quandinh/Downloads/result.txt')

peak = findPeakIndex(psd)

# the highest peak represent the respiratory rate
respiratoryRateFrequency = frequencies[peak]

command = f'echo {respiratoryRateFrequency}'

os.system(command)
