import argparse
import numpy as np
import matplotlib.pyplot as plt
from dataclasses import dataclass


@dataclass
class SignalConfig:
    # Sampling
    sample_rate: int = 250

    # Heart rate
    bpm: float = 72.0
    duration_s: float = 120.0

    # ECG baseline and amplitudes
    baseline: float = 20000.0
    p_level: float = 25000.0
    q_level: float = 17500.0
    r_level: float = 52000.0
    s_level: float = 14500.0
    t_level: float = 28000.0

    # Wave widths (seconds)
    p_sigma_s: float = 0.040
    q_sigma_s: float = 0.012
    r_sigma_s: float = 0.018
    s_sigma_s: float = 0.015
    t_sigma_s: float = 0.075

    # Wave offsets relative to R peak (seconds)
    p_offset_s: float = -0.20
    q_offset_s: float = -0.045
    s_offset_s: float = 0.055
    t_offset_s: float = 0.28

    # Heart-rate variability
    hr_variability: float = 4.0
    hr_modulation_hz: float = 0.015
    hr_random_std: float = 1.2

    # Morphology variability
    amplitude_variability: float = 0.05
    width_variability: float = 0.04

    # Baseline wander
    baseline_wander_amplitude: float = 500.0
    baseline_wander_frequency: float = 0.20

    # Measurement noise
    noise_std: float = 100.0

    # Reproducibility
    random_seed: int = 1234

    # FPGA / software detector threshold
    threshold: int = 30000


def bpm_to_interval(bpm: float, sample_rate: int) -> int:
    """
    Convert BPM to the nominal number of samples between beats.
    """
    return max(1, int(round(60.0 * sample_rate / bpm)))


def gaussian(x: np.ndarray, center: float, sigma: float) -> np.ndarray:
    """
    Gaussian waveform centered at 'center'.
    """
    return np.exp(-0.5 * ((x - center) / sigma) ** 2)


def generate_ecg_signal(config: SignalConfig):
    """
    Generate a synthetic ECG signal.

    Returns
    -------
    time_s : np.ndarray
        Time vector in seconds.

    signal : np.ndarray
        ECG samples as uint16.

    r_peak_samples : np.ndarray
        Sample indices corresponding to the generated R peaks.

    nominal_interval : int
        Nominal RR interval in samples.
    """

    rng = np.random.default_rng(config.random_seed)

    sample_rate = config.sample_rate
    n_samples = int(round(config.duration_s * sample_rate))

    time_s = np.arange(n_samples) / sample_rate
    signal = np.full(
        n_samples,
        config.baseline,
        dtype=np.float64
    )

    nominal_interval = bpm_to_interval(
        config.bpm,
        sample_rate
    )

    # ------------------------------------------------------------------
    # Generate variable R-peak positions
    # ------------------------------------------------------------------

    r_peak_samples = []

    current_sample = 0

    while True:

        if current_sample >= n_samples:
            break

        # Instantaneous BPM:
        # nominal value + slow modulation + random variation
        current_time = current_sample / sample_rate

        modulation = (
            config.hr_variability
            * np.sin(
                2.0
                * np.pi
                * config.hr_modulation_hz
                * current_time
            )
        )

        random_variation = rng.normal(
            0.0,
            config.hr_random_std
        )

        instantaneous_bpm = (
            config.bpm
            + modulation
            + random_variation
        )

        # Keep BPM in a physiological range
        instantaneous_bpm = np.clip(
            instantaneous_bpm,
            40.0,
            180.0
        )

        interval_s = 60.0 / instantaneous_bpm
        interval_samples = max(
            1,
            int(round(interval_s * sample_rate))
        )

        r_peak_samples.append(current_sample)

        current_sample += interval_samples

    r_peak_samples = np.array(
        r_peak_samples,
        dtype=np.int64
    )

    # ------------------------------------------------------------------
    # Add ECG morphology for each beat
    # ------------------------------------------------------------------

    for r_sample in r_peak_samples:

        r_time = r_sample / sample_rate

        # Random amplitude variation
        amplitude_scale = 1.0 + rng.normal(
            0.0,
            config.amplitude_variability
        )

        # Random width variation
        width_scale = 1.0 + rng.normal(
            0.0,
            config.width_variability
        )

        # Avoid unrealistic widths
        width_scale = np.clip(
            width_scale,
            0.85,
            1.15
        )

        # --------------------------------------------------------------
        # P wave
        # --------------------------------------------------------------

        p_center = r_time + config.p_offset_s
        p_sigma = config.p_sigma_s * width_scale

        signal += (
            (config.p_level - config.baseline)
            * amplitude_scale
            * gaussian(
                time_s,
                p_center,
                p_sigma
            )
        )

        # --------------------------------------------------------------
        # Q wave
        # --------------------------------------------------------------

        q_center = r_time + config.q_offset_s
        q_sigma = config.q_sigma_s * width_scale

        signal += (
            (config.q_level - config.baseline)
            * amplitude_scale
            * gaussian(
                time_s,
                q_center,
                q_sigma
            )
        )

        # --------------------------------------------------------------
        # R wave
        # --------------------------------------------------------------

        r_sigma = config.r_sigma_s * width_scale

        signal += (
            (config.r_level - config.baseline)
            * amplitude_scale
            * gaussian(
                time_s,
                r_time,
                r_sigma
            )
        )

        # --------------------------------------------------------------
        # S wave
        # --------------------------------------------------------------

        s_center = r_time + config.s_offset_s
        s_sigma = config.s_sigma_s * width_scale

        signal += (
            (config.s_level - config.baseline)
            * amplitude_scale
            * gaussian(
                time_s,
                s_center,
                s_sigma
            )
        )

        # --------------------------------------------------------------
        # T wave
        # --------------------------------------------------------------

        t_center = r_time + config.t_offset_s
        t_sigma = config.t_sigma_s * width_scale

        signal += (
            (config.t_level - config.baseline)
            * amplitude_scale
            * gaussian(
                time_s,
                t_center,
                t_sigma
            )
        )

    # ------------------------------------------------------------------
    # Baseline wander
    # ------------------------------------------------------------------

    baseline_wander = (
        config.baseline_wander_amplitude
        * np.sin(
            2.0
            * np.pi
            * config.baseline_wander_frequency
            * time_s
        )
    )

    signal += baseline_wander

    # ------------------------------------------------------------------
    # Gaussian measurement noise
    # ------------------------------------------------------------------

    noise = rng.normal(
        0.0,
        config.noise_std,
        n_samples
    )

    signal += noise

    # ------------------------------------------------------------------
    # Clip to uint16 range
    # ------------------------------------------------------------------

    signal = np.clip(
        signal,
        0,
        65535
    ).astype(np.uint16)

    return (
        time_s,
        signal,
        r_peak_samples,
        nominal_interval
    )


def generate_signal(config: SignalConfig):
    """
    Compatibility wrapper.

    This function is kept so that older Python files using
    generate_signal() continue to work.
    """
    return generate_ecg_signal(config)


def plot_ecg(
    time_s: np.ndarray,
    signal: np.ndarray,
    r_peak_samples: np.ndarray | None = None,
    config: SignalConfig | None = None
):
    """
    Plot the generated ECG signal.
    """

    plt.figure(figsize=(14, 5))

    plt.plot(
        time_s,
        signal,
        linewidth=0.8,
        label="Synthetic ECG"
    )

    if config is not None:
        plt.axhline(
            config.threshold,
            linestyle="--",
            linewidth=1.2,
            label="Detection threshold"
        )

    if r_peak_samples is not None:

        valid = r_peak_samples[
            r_peak_samples < len(signal)
        ]

        plt.scatter(
            time_s[valid],
            signal[valid],
            s=20,
            marker="o",
            label="Generated R peaks"
        )

    plt.xlabel("Time [s]")
    plt.ylabel("ADC value")
    plt.title("Synthetic ECG Signal")

    plt.grid(True, alpha=0.3)
    plt.legend()

    plt.tight_layout()
    plt.show()


def main():
    """
    Optional standalone visualization.
    """

    parser = argparse.ArgumentParser(
        description="Synthetic ECG signal generator"
    )

    parser.add_argument(
        "--duration",
        type=float,
        default=120.0,
        help="Signal duration in seconds"
    )

    parser.add_argument(
        "--bpm",
        type=float,
        default=72.0,
        help="Nominal heart rate"
    )

    parser.add_argument(
        "--sample-rate",
        type=int,
        default=250,
        help="Sampling frequency"
    )

    args = parser.parse_args()

    config = SignalConfig(
        duration_s=args.duration,
        bpm=args.bpm,
        sample_rate=args.sample_rate
    )

    (
        time_s,
        signal,
        r_peak_samples,
        nominal_interval
    ) = generate_ecg_signal(config)

    print("Synthetic ECG generated")
    print("-----------------------")
    print(f"Duration       : {config.duration_s:.2f} s")
    print(f"Sample rate    : {config.sample_rate} Hz")
    print(f"Samples        : {len(signal)}")
    print(f"Nominal BPM    : {config.bpm:.2f}")
    print(f"Nominal interval: {nominal_interval} samples")
    print(f"Generated beats: {len(r_peak_samples)}")

    plot_ecg(
        time_s,
        signal,
        r_peak_samples,
        config
    )


if __name__ == "__main__":
    main()