import os
import sys
from scipy import signal    # https://scipy.org/install/
import numpy as np

samples = sys.argv[1].split(',')

def low_pass_filter(data, band_limit, sampling_rate):
     cutoff_index = int(band_limit * data.size / sampling_rate)
     F = np.fft.rfft(data)
     F[cutoff_index + 1:] = 0
     return np.fft.irfft(F, n=data.size).real

envelope = np.abs(signal.hilbert(samples))

fs = 1000  # Sampling frequency in Hz
t = np.arange(0, 10, 1/fs)  # Time array for 5 seconds

# Define lowpass filter parameters
cutoff_freq = 2  # Cutoff frequency in Hz
nyquist_freq = 0.5 * fs  # Nyquist frequency
normal_cutoff = cutoff_freq / nyquist_freq

# Design a Butterworth lowpass filter
order = 4  # Filter order
b, a = signal.butter(order, normal_cutoff, btype='low', analog=False)

# Apply the filter to the signal envelope
filtered = signal.filtfilt(b, a, envelope)

# hanning window to smoothing the filtered
window = np.hanning(len(filtered))
windowed = filtered * window

# now downsample to 10 Hz
downSampled2 = signal.resample(windowed, 100)

# apply Welch perdiogram to estimate power spectral density
frequencyArray, psd = signal.welch(downSampled2, 10, nperseg = 100)

peaks, _ = signal.find_peaks(psd)

respiratoryRate = peaks.max()

command = f'echo {respiratoryRate}'

os.system(command)
