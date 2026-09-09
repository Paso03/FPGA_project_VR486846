import argparse
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from signal_generator import SignalConfig, generate_ecg_signal


# ============================================================================
# FILES
# ============================================================================

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_BITFILE = BASE_DIR / "system.bit"


# ============================================================================
# AXI-LITE REGISTER MAP
# ============================================================================

REG_CONTROL = 0x00
REG_SAMPLE = 0x04
REG_STATUS = 0x08
REG_BPM = 0x0C
REG_BEAT_COUNT = 0x10
REG_LAST_INTERVAL = 0x14
REG_AVG_INTERVAL = 0x18
REG_MIN_BPM = 0x1C
REG_MAX_BPM = 0x20
REG_SAMPLE_COUNT = 0x24
REG_THRESHOLD = 0x28
REG_SAMPLE_RATE = 0x2C


# ============================================================================
# CONTROL REGISTER BITS
# ============================================================================

CONTROL_SAMPLE_VALID = 1 << 0
CONTROL_CLEAR = 1 << 1
CONTROL_START = 1 << 2
CONTROL_STOP = 1 << 3


# ============================================================================
# STATUS REGISTER BITS
# ============================================================================

STATUS_BUSY = 1 << 0
STATUS_BEAT_DETECTED = 1 << 1
STATUS_BPM_VALID = 1 << 2
STATUS_PROCESSING_DONE = 1 << 3


# ============================================================================
# RESULT
# ============================================================================

@dataclass
class HRResult:
    bpm: int
    min_bpm: int
    max_bpm: int
    beat_count: int
    last_interval: int
    avg_interval: int
    sample_count: int
    processing_done: bool


# ============================================================================
# SOFTWARE REFERENCE DETECTOR
# ============================================================================

class SoftwareHeartRateMonitor:
    """
    Software reference implementation that mirrors the Verilog algorithm.
    Used for offline verification on the PC.
    """

    def __init__(
        self,
        sample_rate: int = 250,
        threshold: int = 30000,
        refractory: int = 50,
    ):
        self.sample_rate = sample_rate
        self.threshold = threshold
        self.refractory = refractory

        self.clear()

    def clear(self):
        self.bpm = 0
        self.min_bpm = 0
        self.max_bpm = 0

        self.beat_count = 0
        self.last_interval = 0
        self.avg_interval = 0
        self.sample_count = 0

        self.busy = False
        self.processing_done = False

        self.refractory_counter = 0
        self.previous_above_threshold = False

        self.last_beat_sample = None
        self.interval_sum = 0
        self.interval_count = 0

        self.detected_peaks = []

    def start(self):
        self.busy = True
        self.processing_done = False

    def stop(self):
        self.busy = False
        self.processing_done = True

    def process_sample(
        self,
        sample: int,
        sample_index: int,
    ) -> bool:
        """
        Process one sample.

        Returns True if a beat is detected.
        """

        if not self.busy:
            return False

        self.sample_count += 1

        if self.refractory_counter > 0:
            self.refractory_counter -= 1

        above_threshold = sample >= self.threshold

        beat_detected = False

        # Rising edge + refractory period
        if (
            above_threshold
            and not self.previous_above_threshold
            and self.refractory_counter == 0
        ):
            beat_detected = True

            self.detected_peaks.append(sample_index)

            self.beat_count += 1

            if self.last_beat_sample is not None:

                interval = (
                    sample_index - self.last_beat_sample
                )

                if interval > 0:

                    self.last_interval = interval

                    self.interval_sum += interval
                    self.interval_count += 1

                    self.avg_interval = (
                        self.interval_sum
                        // self.interval_count
                    )

                    instantaneous_bpm = (
                        60 * self.sample_rate
                    ) // interval

                    if self.min_bpm == 0:
                        self.min_bpm = instantaneous_bpm
                    else:
                        self.min_bpm = min(
                            self.min_bpm,
                            instantaneous_bpm,
                        )

                    self.max_bpm = max(
                        self.max_bpm,
                        instantaneous_bpm,
                    )

                    if self.avg_interval > 0:
                        self.bpm = (
                            60 * self.sample_rate
                        ) // self.avg_interval

            self.last_beat_sample = sample_index

            self.refractory_counter = self.refractory

        self.previous_above_threshold = above_threshold

        return beat_detected

    def get_result(self) -> HRResult:
        return HRResult(
            bpm=self.bpm,
            min_bpm=self.min_bpm,
            max_bpm=self.max_bpm,
            beat_count=self.beat_count,
            last_interval=self.last_interval,
            avg_interval=self.avg_interval,
            sample_count=self.sample_count,
            processing_done=self.processing_done,
        )


# ============================================================================
# PYNQ FPGA INTERFACE
# ============================================================================

class PYNQHeartRateMonitor:
    """
    Interface to the heart_rate_ip_0 AXI-Lite IP.
    """

    def __init__(
        self,
        bitfile: str = str(DEFAULT_BITFILE),
        ip_name: str = "heart_rate_ip_0",
    ):
        try:
            from pynq import Overlay
        except ImportError as exc:
            raise RuntimeError(
                "PYNQ is not available. "
                "Hardware mode must be executed on the PYNQ-Z1."
            ) from exc

        print()
        print("Loading FPGA overlay...")
        print(f"Bitstream: {bitfile}")

        self.overlay = Overlay(str(bitfile))

        try:
            self.ip = getattr(
                self.overlay,
                ip_name,
            )
        except AttributeError as exc:
            raise RuntimeError(
                f"IP '{ip_name}' was not found in the overlay."
            ) from exc

        print(f"IP found: {ip_name}")

    def write(self, offset: int, value: int):
        self.ip.write(
            offset,
            int(value),
        )

    def read(self, offset: int) -> int:
        return int(
            self.ip.read(offset)
        )

    def pulse_control(self, bit: int):
        """
        Write a control command and then clear the control register.
        """

        self.write(
            REG_CONTROL,
            bit,
        )

        self.write(
            REG_CONTROL,
            0,
        )

    def configure(
        self,
        sample_rate: int,
        threshold: int,
    ):
        self.write(
            REG_THRESHOLD,
            threshold,
        )

        self.write(
            REG_SAMPLE_RATE,
            sample_rate,
        )

        self.pulse_control(
            CONTROL_CLEAR
        )

    def start(self):
        self.pulse_control(
            CONTROL_START
        )

    def stop(self):
        self.pulse_control(
            CONTROL_STOP
        )

    def send_sample(self, sample: int):
        """
        Send one 16-bit ECG sample.

        The sequence is:

            SAMPLE register
                 ↓
            SAMPLE_VALID = 1
                 ↓
            SAMPLE_VALID = 0
        """

        sample &= 0xFFFF

        self.write(
            REG_SAMPLE,
            sample,
        )

        self.write(
            REG_CONTROL,
            CONTROL_SAMPLE_VALID,
        )

        self.write(
            REG_CONTROL,
            0,
        )

    def read_status(self) -> int:
        return self.read(REG_STATUS)

    def wait_processing_done(
        self,
        timeout_s: float = 2.0,
    ):
        """
        Wait until the FPGA asserts PROCESSING_DONE.
        """

        start_time = time.time()

        while True:

            status = self.read_status()

            if status & STATUS_PROCESSING_DONE:
                return True

            if time.time() - start_time >= timeout_s:
                return False

            time.sleep(0.001)

    def read_result(self) -> HRResult:

        status = self.read(
            REG_STATUS
        )

        return HRResult(
            bpm=self.read(REG_BPM),
            min_bpm=self.read(REG_MIN_BPM),
            max_bpm=self.read(REG_MAX_BPM),
            beat_count=self.read(REG_BEAT_COUNT),
            last_interval=self.read(
                REG_LAST_INTERVAL
            ),
            avg_interval=self.read(
                REG_AVG_INTERVAL
            ),
            sample_count=self.read(
                REG_SAMPLE_COUNT
            ),
            processing_done=bool(
                status & STATUS_PROCESSING_DONE
            ),
        )


# ============================================================================
# GROUND TRUTH
# ============================================================================

def calculate_ground_truth(
    r_peak_samples: np.ndarray,
    sample_rate: int,
):
    """
    Calculate BPM statistics from generated R peaks.
    """

    if len(r_peak_samples) < 2:

        return {
            "beat_count": len(r_peak_samples),
            "avg_bpm": 0.0,
            "min_bpm": 0.0,
            "max_bpm": 0.0,
            "avg_interval": 0.0,
        }

    intervals = np.diff(
        r_peak_samples
    )

    bpm_values = (
        60.0
        * sample_rate
        / intervals
    )

    return {
        "beat_count": len(r_peak_samples),
        "avg_bpm": float(
            np.mean(bpm_values)
        ),
        "min_bpm": float(
            np.min(bpm_values)
        ),
        "max_bpm": float(
            np.max(bpm_values)
        ),
        "avg_interval": float(
            np.mean(intervals)
        ),
    }


# ============================================================================
# PEAK MATCHING
# ============================================================================

def match_peaks(
    ground_truth: np.ndarray,
    detected: np.ndarray,
    tolerance_samples: int = 20,
):
    """
    Match FPGA/software detected beats with ground truth.
    """

    i = 0
    j = 0

    errors = []

    while (
        i < len(ground_truth)
        and j < len(detected)
    ):

        error = int(
            detected[j]
            - ground_truth[i]
        )

        if abs(error) <= tolerance_samples:

            errors.append(
                abs(error)
            )

            i += 1
            j += 1

        elif detected[j] < ground_truth[i]:
            j += 1

        else:
            i += 1

    return np.array(
        errors,
        dtype=np.float64,
    )


# ============================================================================
# PLOT
# ============================================================================

def plot_verification(
    time_s,
    signal,
    ground_truth_peaks,
    detected_peaks,
    threshold,
    max_time=None,
):
    """
    Plot the ECG signal and detection results.
    """

    import matplotlib.pyplot as plt

    if max_time is None:

        max_samples = len(signal)

    else:

        max_samples = min(
            len(signal),
            int(
                round(
                    max_time
                    / (time_s[1] - time_s[0])
                )
            ),
        )

    time_plot = time_s[
        :max_samples
    ]

    signal_plot = signal[
        :max_samples
    ]

    gt = ground_truth_peaks[
        ground_truth_peaks < max_samples
    ]

    det = detected_peaks[
        detected_peaks < max_samples
    ]

    plt.figure(
        figsize=(14, 5)
    )

    plt.plot(
        time_plot,
        signal_plot,
        linewidth=0.8,
        label="Synthetic ECG",
    )

    plt.axhline(
        threshold,
        linestyle="--",
        linewidth=1.2,
        label="Threshold",
    )

    if len(gt) > 0:

        plt.scatter(
            time_s[gt],
            signal[gt],
            marker="o",
            s=25,
            label="Ground truth R peaks",
        )

    if len(det) > 0:

        plt.scatter(
            time_s[det],
            signal[det],
            marker="x",
            s=30,
            label="Detected beats",
        )

    plt.xlabel("Time [s]")
    plt.ylabel("ADC value")
    plt.title(
        "Heart Rate Monitor Verification"
    )

    plt.grid(
        True,
        alpha=0.3,
    )

    plt.legend()
    plt.tight_layout()
    plt.show()


# ============================================================================
# OFFLINE SIMULATION
# ============================================================================

def run_simulation(
    config: SignalConfig,
    signal: np.ndarray,
):
    """
    Run the software reference implementation.
    """

    monitor = SoftwareHeartRateMonitor(
        sample_rate=config.sample_rate,
        threshold=config.threshold,
        refractory=50,
    )

    monitor.clear()
    monitor.start()

    for sample_index, sample in enumerate(signal):

        monitor.process_sample(
            int(sample),
            sample_index,
        )

    monitor.stop()

    result = monitor.get_result()

    detected_peaks = np.array(
        monitor.detected_peaks,
        dtype=np.int64,
    )

    return result, detected_peaks


# ============================================================================
# HARDWARE EXECUTION
# ============================================================================

def run_hardware(
    config: SignalConfig,
    signal: np.ndarray,
    bitfile: str,
    ip_name: str,
):
    """
    Send ECG samples to the FPGA.
    """

    monitor = PYNQHeartRateMonitor(
        bitfile=bitfile,
        ip_name=ip_name,
    )

    # Configure detector
    monitor.configure(
        sample_rate=config.sample_rate,
        threshold=config.threshold,
    )

    # Start processing
    monitor.start()

    print()
    print("Sending ECG samples to FPGA...")
    print(
        f"Samples: {len(signal)}"
    )

    last_percent = -1

    for index, sample in enumerate(signal):

        monitor.send_sample(
            int(sample)
        )

        # Progress indication
        percent = int(
            100
            * (index + 1)
            / len(signal)
        )

        if percent != last_percent:

            if percent % 5 == 0:

                print(
                    f"Progress: {percent}%"
                )

            last_percent = percent

    # Stop processing
    monitor.stop()

    # Wait for processing_done
    done = monitor.wait_processing_done()

    if not done:

        print(
            "Warning: PROCESSING_DONE "
            "was not detected within timeout."
        )

    return monitor.read_result()


# ============================================================================
# SIGNAL INFORMATION
# ============================================================================

def print_signal_info(
    config: SignalConfig,
    signal: np.ndarray,
):
    print()
    print("=" * 75)
    print(
        "             FPGA HEART RATE MONITOR"
    )
    print("=" * 75)

    print()
    print("SIGNAL")
    print("-" * 75)

    print(
        f"Duration              : "
        f"{config.duration_s:.2f} s"
    )

    print(
        f"Sampling frequency    : "
        f"{config.sample_rate} Hz"
    )

    print(
        f"Samples generated     : "
        f"{len(signal)}"
    )

    print(
        f"Nominal BPM           : "
        f"{config.bpm:.0f}"
    )

    print(
        f"Nominal interval      : "
        f"{round(60 * config.sample_rate / config.bpm)} samples"
    )

    print(
        f"Noise standard dev.   : "
        f"{config.noise_std:.1f}"
    )


# ============================================================================
# SIMULATION RESULTS
# ============================================================================

def print_simulation_results(
    config: SignalConfig,
    r_peak_samples: np.ndarray,
    result: HRResult,
    detected_peaks: np.ndarray,
):
    ground_truth = calculate_ground_truth(
        r_peak_samples,
        config.sample_rate,
    )

    errors = match_peaks(
        r_peak_samples,
        detected_peaks,
        tolerance_samples=20,
    )

    matched_beats = len(errors)

    mean_error = (
        float(np.mean(errors))
        if len(errors) > 0
        else 0.0
    )

    max_error = (
        int(np.max(errors))
        if len(errors) > 0
        else 0
    )

    if ground_truth["avg_bpm"] > 0:

        bpm_error = (
            abs(
                result.bpm
                - ground_truth["avg_bpm"]
            )
            / ground_truth["avg_bpm"]
            * 100.0
        )

    else:

        bpm_error = 0.0

    print()
    print("GROUND TRUTH")
    print("-" * 75)

    print(
        f"Generated beats       : "
        f"{ground_truth['beat_count']}"
    )

    print(
        f"Average BPM           : "
        f"{ground_truth['avg_bpm']:.2f}"
    )

    print(
        f"Minimum BPM           : "
        f"{ground_truth['min_bpm']:.2f}"
    )

    print(
        f"Maximum BPM           : "
        f"{ground_truth['max_bpm']:.2f}"
    )

    print(
        f"Average interval      : "
        f"{ground_truth['avg_interval']:.2f}"
    )

    print()
    print("REFERENCE DETECTOR")
    print("-" * 75)

    print(
        f"Detected beats        : "
        f"{result.beat_count}"
    )

    print(
        f"Average BPM           : "
        f"{result.bpm}"
    )

    print(
        f"Minimum BPM           : "
        f"{result.min_bpm}"
    )

    print(
        f"Maximum BPM           : "
        f"{result.max_bpm}"
    )

    print(
        f"Average interval      : "
        f"{result.avg_interval}"
    )

    print(
        f"Last interval         : "
        f"{result.last_interval}"
    )

    print(
        f"Samples processed     : "
        f"{result.sample_count}"
    )

    print(
        f"Duration              : "
        f"{result.sample_count / config.sample_rate:.2f} s"
    )

    print()
    print("VERIFICATION")
    print("-" * 75)

    print(
        f"Generated beats       : "
        f"{len(r_peak_samples)}"
    )

    print(
        f"Detected beats        : "
        f"{len(detected_peaks)}"
    )

    print(
        f"Matched beats         : "
        f"{matched_beats}"
    )

    print(
        f"Mean position error   : "
        f"{mean_error:.2f} samples"
    )

    print(
        f"Max position error    : "
        f"{max_error} samples"
    )

    print(
        f"Average BPM error     : "
        f"{bpm_error:.2f}%"
    )

    expected_samples = int(
        round(
            config.duration_s
            * config.sample_rate
        )
    )

    passed = (
        len(r_peak_samples)
        == len(detected_peaks)
        and matched_beats
        == len(r_peak_samples)
        and bpm_error <= 2.0
        and result.sample_count
        == expected_samples
    )

    print()
    print("-" * 75)

    if passed:
        print("STATUS: PASS")
    else:
        print("STATUS: FAIL")

    print("-" * 75)

    return passed


# ============================================================================
# HARDWARE RESULTS
# ============================================================================

def print_hardware_results(
    config: SignalConfig,
    signal: np.ndarray,
    r_peak_samples: np.ndarray,
    result: HRResult,
):
    ground_truth = calculate_ground_truth(
        r_peak_samples,
        config.sample_rate,
    )

    if ground_truth["avg_bpm"] > 0:

        bpm_error = (
            abs(
                result.bpm
                - ground_truth["avg_bpm"]
            )
            / ground_truth["avg_bpm"]
            * 100.0
        )

    else:

        bpm_error = 0.0

    expected_samples = len(signal)

    count_ok = (
        result.beat_count
        == ground_truth["beat_count"]
    )

    bpm_ok = (
        bpm_error <= 2.0
    )

    samples_ok = (
        result.sample_count
        == expected_samples
    )

    done_ok = (
        result.processing_done
    )

    print()
    print("GROUND TRUTH")
    print("-" * 75)

    print(
        f"Generated beats       : "
        f"{ground_truth['beat_count']}"
    )

    print(
        f"Average BPM           : "
        f"{ground_truth['avg_bpm']:.2f}"
    )

    print(
        f"Minimum BPM           : "
        f"{ground_truth['min_bpm']:.2f}"
    )

    print(
        f"Maximum BPM           : "
        f"{ground_truth['max_bpm']:.2f}"
    )

    print(
        f"Average interval      : "
        f"{ground_truth['avg_interval']:.2f}"
    )

    print()
    print("FPGA")
    print("-" * 75)

    print(
        f"Detected beats        : "
        f"{result.beat_count}"
    )

    print(
        f"Average BPM           : "
        f"{result.bpm}"
    )

    print(
        f"Minimum BPM           : "
        f"{result.min_bpm}"
    )

    print(
        f"Maximum BPM           : "
        f"{result.max_bpm}"
    )

    print(
        f"Average interval      : "
        f"{result.avg_interval}"
    )

    print(
        f"Last interval         : "
        f"{result.last_interval}"
    )

    print(
        f"Samples processed     : "
        f"{result.sample_count}"
    )

    print(
        f"Expected samples      : "
        f"{expected_samples}"
    )

    print(
        f"Processing done       : "
        f"{result.processing_done}"
    )

    print()
    print("VERIFICATION")
    print("-" * 75)

    print(
        f"Beat count            : "
        f"{'OK' if count_ok else 'ERROR'}"
    )

    print(
        f"Average BPM error     : "
        f"{bpm_error:.2f}%"
    )

    print(
        f"BPM                   : "
        f"{'OK' if bpm_ok else 'ERROR'}"
    )

    print(
        f"Sample count          : "
        f"{'OK' if samples_ok else 'ERROR'}"
    )

    print(
        f"Processing done       : "
        f"{'OK' if done_ok else 'ERROR'}"
    )

    passed = (
        count_ok
        and bpm_ok
        and samples_ok
        and done_ok
    )

    print()
    print("-" * 75)

    if passed:
        print("STATUS: PASS")
    else:
        print("STATUS: FAIL")

    print("-" * 75)

    return passed


# ============================================================================
# MAIN
# ============================================================================

def main():

    parser = argparse.ArgumentParser(
        description="FPGA Heart Rate Monitor"
    )

    parser.add_argument(
        "--mode",
        choices=[
            "simulation",
            "hardware",
        ],
        default="simulation",
    )

    parser.add_argument(
        "--duration",
        type=float,
        default=120.0,
    )

    parser.add_argument(
        "--bpm",
        type=float,
        default=72.0,
    )

    parser.add_argument(
        "--sample-rate",
        type=int,
        default=250,
    )

    parser.add_argument(
        "--threshold",
        type=int,
        default=30000,
    )

    parser.add_argument(
        "--bitfile",
        type=str,
        default=str(DEFAULT_BITFILE),
    )

    parser.add_argument(
        "--ip-name",
        type=str,
        default="heart_rate_ip_0",
    )

    parser.add_argument(
        "--plot",
        action="store_true",
    )

    parser.add_argument(
        "--plot-seconds",
        type=float,
        default=None,
    )

    args = parser.parse_args()

    # ------------------------------------------------------------------
    # Generate ECG
    # ------------------------------------------------------------------

    config = SignalConfig(
        sample_rate=args.sample_rate,
        bpm=args.bpm,
        duration_s=args.duration,
        threshold=args.threshold,
    )

    (
        time_s,
        signal,
        r_peak_samples,
        nominal_interval,
    ) = generate_ecg_signal(config)

    print_signal_info(
        config,
        signal,
    )

    # ------------------------------------------------------------------
    # SIMULATION
    # ------------------------------------------------------------------

    if args.mode == "simulation":

        result, detected_peaks = run_simulation(
            config,
            signal,
        )

        passed = print_simulation_results(
            config,
            r_peak_samples,
            result,
            detected_peaks,
        )

        if args.plot:

            plot_verification(
                time_s,
                signal,
                r_peak_samples,
                detected_peaks,
                config.threshold,
                args.plot_seconds,
            )

    # ------------------------------------------------------------------
    # HARDWARE
    # ------------------------------------------------------------------

    else:

        result = run_hardware(
            config,
            signal,
            args.bitfile,
            args.ip_name,
        )

        passed = print_hardware_results(
            config,
            signal,
            r_peak_samples,
            result,
        )

        if args.plot:

            plot_verification(
                time_s,
                signal,
                r_peak_samples,
                np.array([], dtype=np.int64),
                config.threshold,
                args.plot_seconds,
            )

    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())