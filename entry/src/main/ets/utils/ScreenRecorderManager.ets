import display from '@ohos.display';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';
import {
  NativeCreateRecorderOptions,
  NativeScreenRecorder,
  NativeStopRecorderResult
} from './NativeScreenRecorder';

export type RecordingPreset = 'H264' | 'H265';

type RecorderLifecycleState = 'idle' | 'initializing' | 'recording' | 'stopping' | 'released';

interface RecorderStateEvent {
  label: string;
  timestampMs: number;
}

export interface ScreenRecordOptions {
  durationSec: number;
  outputDir: string;
  videoBitrate: number;
  preset: RecordingPreset;
  micEnabled?: boolean;
  frameWidth?: number;
  frameHeight?: number;
}

export interface RecordingAnalysisResult {
  status: 'NORMAL' | 'WARNING' | 'ABNORMAL';
  message: string;
  outputPath: string;
  requestedDurationSec: number;
  wallClockDurationMs: number;
  metadataDurationMs: number;
  durationDriftMs: number;
  fileSizeBytes: number;
  avgBitrateMbps: number;
  frameWidth: number;
  frameHeight: number;
  configuredBitrate: number;
  preset: RecordingPreset;
  mimeType: string;
  hasVideo: boolean;
  hasAudio: boolean;
  initTimeMs: number;
  startLatencyMs: number;
  stopLatencyMs: number;
  finalizeTimeMs: number;
  stateEvents: string[];
  errorMessage: string;
}

export class ScreenRecorderManager {
  private recorderId: number = -1;
  private nativeModuleVersion: string = '';
  private lifecycleState: RecorderLifecycleState = 'idle';
  private outputPath: string = '';
  private progressTimerId: number = -1;
  private autoStopTimerId: number = -1;
  private completionPromise: Promise<RecordingAnalysisResult> | null = null;
  private completionResolve: ((result: RecordingAnalysisResult) => void) | null = null;
  private completionReject: ((error: Error) => void) | null = null;
  private progressCallback: ((progress: number) => void) | null = null;
  private stateEvents: RecorderStateEvent[] = [];
  private errorMessage: string = '';
  private terminalStateMessage: string = '';
  private hasStartedRecording: boolean = false;
  private resolvedWidth: number = 0;
  private resolvedHeight: number = 0;
  private nativeStopResult: NativeStopRecorderResult | null = null;

  private initStartedAtMs: number = 0;
  private initCompletedAtMs: number = 0;
  private startRequestedAtMs: number = 0;
  private recordingStartedAtMs: number = 0;
  private stopRequestedAtMs: number = 0;
  private stopCompletedAtMs: number = 0;
  private finalizeCompletedAtMs: number = 0;

  private readonly options: ScreenRecordOptions;

  constructor(options: ScreenRecordOptions) {
    this.options = options;
  }

  async startRecording(onProgress?: (progress: number) => void): Promise<RecordingAnalysisResult> {
    if (this.completionPromise) {
      throw new Error('Recording already in progress');
    }

    this.resetRunState();
    this.progressCallback = onProgress ?? null;
    const completionPromise = new Promise<RecordingAnalysisResult>((resolve, reject) => {
      this.completionResolve = resolve;
      this.completionReject = reject;
    });
    this.completionPromise = completionPromise;

    try {
      this.ensureOutputDir();
      this.prepareOutputPath();
      this.resolveFrameSize();
      this.logPreparedOutputPath();
      await this.logNativeModuleVersion();

      this.lifecycleState = 'initializing';
      this.addStateEvent('NATIVE_CREATE_REQUESTED');
      this.initStartedAtMs = Date.now();
      const createOptions = this.buildCreateRecorderOptions();
      this.logCreateRecorderOptions(createOptions);
      const createResult = await NativeScreenRecorder.createRecorder(createOptions);
      this.recorderId = createResult.recorderId;
      this.initCompletedAtMs = Date.now();
      this.addStateEvent(`NATIVE_CREATE_COMPLETED_${this.recorderId}`);

      this.startRequestedAtMs = Date.now();
      this.addStateEvent('NATIVE_START_REQUESTED');
      console.info(`[Recorder] Starting native recorder, path=${this.outputPath}, bitrate=${this.options.videoBitrate}, preset=${this.options.preset}, width=${this.resolvedWidth}, height=${this.resolvedHeight}, recorderId=${this.recorderId}`);
      await NativeScreenRecorder.startRecorder(this.recorderId);
      this.recordingStartedAtMs = Date.now();
      this.hasStartedRecording = true;
      this.lifecycleState = 'recording';
      this.addStateEvent('NATIVE_START_COMPLETED');

      this.startProgressLoop();
      this.armAutoStop();
      console.info(`[Recorder] Native recorder started to ${this.outputPath}`);
    } catch (err) {
      this.errorMessage = `Start recording failed: code=${this.getErrorCode(err)}, message=${this.getErrorMessage(err)}, ${this.describeOutputFileForError()}`;
      console.error(`[Recorder] ${this.errorMessage}`);
      await this.disposeResources();
      this.rejectCompletion(new Error(this.errorMessage));
    }

    return await completionPromise;
  }

  async stopRecording(reason: string = 'manual'): Promise<void> {
    if (!this.completionPromise) {
      return;
    }

    await this.finishRecording(reason);
  }

  async cleanup(): Promise<void> {
    if (this.completionPromise && this.lifecycleState !== 'released') {
      await this.finishRecording('cleanup');
      return;
    }

    this.clearTimers();
    await this.disposeResources();
    this.resetCompletion();
    this.lifecycleState = 'idle';
  }

  private ensureOutputDir(): void {
    if (!fs.accessSync(this.options.outputDir)) {
      fs.mkdirSync(this.options.outputDir, true);
    }
  }

  private prepareOutputPath(): void {
    const timestamp = Date.now();
    this.outputPath = `${this.options.outputDir}/screen_record_${timestamp}.mp4`;
  }

  private resolveFrameSize(): void {
    const defaultDisplay = display.getDefaultDisplaySync();
    this.resolvedWidth = this.options.frameWidth ?? defaultDisplay.width;
    this.resolvedHeight = this.options.frameHeight ?? defaultDisplay.height;
  }

  private buildCreateRecorderOptions(): NativeCreateRecorderOptions {
    return {
      outputPath: this.outputPath,
      width: this.resolvedWidth,
      height: this.resolvedHeight,
      frameRate: 60,
      videoBitrate: this.options.videoBitrate,
      preset: this.options.preset,
      micEnabled: this.options.micEnabled ?? false
    };
  }

  private startProgressLoop(): void {
    this.progressTimerId = setInterval(() => {
      if (!this.progressCallback || !this.recordingStartedAtMs) {
        return;
      }

      const elapsedMs = Date.now() - this.recordingStartedAtMs;
      const totalMs = this.options.durationSec * 1000;
      const progress = Math.min(1, elapsedMs / totalMs);
      this.progressCallback(progress);
    }, 200);
  }

  private armAutoStop(): void {
    this.autoStopTimerId = setTimeout(() => {
      void this.finishRecording('duration_complete');
    }, this.options.durationSec * 1000);
  }

  private async finishRecording(reason: string): Promise<void> {
    if (!this.completionPromise || this.lifecycleState === 'released') {
      return;
    }

    if (this.lifecycleState === 'stopping') {
      await this.completionPromise.then(() => undefined, () => undefined);
      return;
    }

    this.lifecycleState = 'stopping';
    this.clearTimers();
    this.addStateEvent(`NATIVE_STOP_REQUESTED_${reason}`);
    console.info(`[Recorder] Finishing recording, reason=${reason}`);

    try {
      if (this.recorderId !== -1 && this.hasStartedRecording) {
        this.stopRequestedAtMs = Date.now();
        this.nativeStopResult = await NativeScreenRecorder.stopRecorder(this.recorderId);
        this.stopCompletedAtMs = Date.now();
        this.addStateEvent('NATIVE_STOP_COMPLETED');
        if (this.nativeStopResult.errorMessage) {
          this.terminalStateMessage = this.nativeStopResult.errorMessage;
        }
      }
    } catch (err) {
      if (!this.errorMessage) {
        this.errorMessage = `Stop recording failed: code=${this.getErrorCode(err)}, message=${this.getErrorMessage(err)}`;
      }
    }

    await this.disposeResources();
    const result = await this.buildAnalysisResult();
    this.resolveCompletion(result);
  }

  private async buildAnalysisResult(): Promise<RecordingAnalysisResult> {
    const fileSizeBytes = this.getOutputFileSize();
    const nativeStopResult = this.nativeStopResult;
    const wallClockDurationMs = nativeStopResult && nativeStopResult.durationMs > 0
      ? nativeStopResult.durationMs
      : this.computeWallClockDurationMs();
    const metadataDurationMs = 0;
    const durationDriftMs = Math.abs(wallClockDurationMs - this.options.durationSec * 1000);
    const avgBitrateMbps = wallClockDurationMs > 0
      ? (fileSizeBytes * 8) / (wallClockDurationMs / 1000) / 1_000_000
      : 0;

    const initTimeMs = this.initCompletedAtMs > 0 && this.initStartedAtMs > 0
      ? this.initCompletedAtMs - this.initStartedAtMs
      : 0;
    const startLatencyMs = this.recordingStartedAtMs > 0 && this.startRequestedAtMs > 0
      ? this.recordingStartedAtMs - this.startRequestedAtMs
      : 0;
    const stopLatencyMs = this.stopCompletedAtMs > 0 && this.stopRequestedAtMs > 0
      ? this.stopCompletedAtMs - this.stopRequestedAtMs
      : 0;
    const finalizeTimeMs = this.finalizeCompletedAtMs > 0 && this.stopRequestedAtMs > 0
      ? this.finalizeCompletedAtMs - this.stopRequestedAtMs
      : 0;

    let status: 'NORMAL' | 'WARNING' | 'ABNORMAL' = 'NORMAL';
    let message = 'Recording finished successfully';

    if (this.errorMessage || this.terminalStateMessage || fileSizeBytes <= 0) {
      status = 'ABNORMAL';
      message = this.errorMessage || this.terminalStateMessage || 'Recording file is invalid';
    } else if (durationDriftMs > 1000 || this.containsStateKeyword('ERROR')) {
      status = 'WARNING';
      message = durationDriftMs > 1000
        ? `Recording duration drifted by ${durationDriftMs} ms`
        : 'Recording completed with recorder warnings';
    }

    return {
      status,
      message,
      outputPath: this.nativeStopResult?.outputPath || this.outputPath,
      requestedDurationSec: this.options.durationSec,
      wallClockDurationMs,
      metadataDurationMs,
      durationDriftMs,
      fileSizeBytes,
      avgBitrateMbps,
      frameWidth: this.nativeStopResult?.frameWidth || this.resolvedWidth,
      frameHeight: this.nativeStopResult?.frameHeight || this.resolvedHeight,
      configuredBitrate: this.options.videoBitrate,
      preset: this.options.preset,
      mimeType: 'video/mp4',
      hasVideo: (this.nativeStopResult?.hasVideo ?? true) && fileSizeBytes > 0,
      hasAudio: false,
      initTimeMs,
      startLatencyMs,
      stopLatencyMs,
      finalizeTimeMs,
      stateEvents: this.stateEvents.map((event) => `${event.label} @ ${new Date(event.timestampMs).toISOString()}`),
      errorMessage: this.errorMessage || this.terminalStateMessage
    };
  }

  private getOutputFileSize(): number {
    if (!this.outputPath || !fs.accessSync(this.outputPath)) {
      return 0;
    }

    try {
      return fs.statSync(this.outputPath).size;
    } catch (_err) {
      return 0;
    }
  }

  private computeWallClockDurationMs(): number {
    if (!this.recordingStartedAtMs) {
      return 0;
    }

    if (this.stopRequestedAtMs > 0) {
      return this.stopRequestedAtMs - this.recordingStartedAtMs;
    }

    return Date.now() - this.recordingStartedAtMs;
  }

  private logPreparedOutputPath(): void {
    const exists = this.outputPath ? fs.accessSync(this.outputPath) : false;
    let size = -1;
    if (exists) {
      try {
        size = fs.statSync(this.outputPath).size;
      } catch (_err) {}
    }

    console.info(`[Recorder] Output path prepared: path=${this.outputPath}, fileExists=${exists}, fileSize=${size}`);
  }

  private async logNativeModuleVersion(): Promise<void> {
    try {
      this.nativeModuleVersion = await NativeScreenRecorder.getVersion();
      console.info(`[NativeRecorder] Loaded native module version: ${this.nativeModuleVersion}`);
    } catch (err) {
      const message = this.getErrorMessage(err);
      console.error(`[NativeRecorder] Failed to load native module: ${message}`);
      throw new Error(`Failed to load native recorder module: ${message}`);
    }
  }

  private logCreateRecorderOptions(options: NativeCreateRecorderOptions): void {
    console.info(`[Recorder] Native options: path=${options.outputPath}, width=${options.width}, height=${options.height}, frameRate=${options.frameRate}, videoBitrate=${options.videoBitrate}, preset=${options.preset}, micEnabled=${options.micEnabled}`);
  }

  private describeOutputFileForError(): string {
    const exists = this.outputPath ? fs.accessSync(this.outputPath) : false;
    let size = -1;

    if (exists) {
      try {
        size = fs.statSync(this.outputPath).size;
      } catch (_err) {}
    }

    return `path=${this.outputPath}, fileExists=${exists}, fileSize=${size}, recorderId=${this.recorderId}`;
  }

  private clearTimers(): void {
    if (this.progressTimerId !== -1) {
      clearInterval(this.progressTimerId);
      this.progressTimerId = -1;
    }

    if (this.autoStopTimerId !== -1) {
      clearTimeout(this.autoStopTimerId);
      this.autoStopTimerId = -1;
    }
  }

  private async disposeResources(): Promise<void> {
    if (this.recorderId !== -1) {
      try {
        NativeScreenRecorder.releaseRecorder(this.recorderId);
        this.addStateEvent('NATIVE_RELEASE_COMPLETED');
      } catch (err) {
        if (!this.errorMessage) {
          this.errorMessage = `Release recorder failed: code=${this.getErrorCode(err)}, message=${this.getErrorMessage(err)}`;
        }
      }
      this.recorderId = -1;
    }

    this.finalizeCompletedAtMs = Date.now();
    this.lifecycleState = 'released';
  }

  private resetRunState(): void {
    this.lifecycleState = 'idle';
    this.recorderId = -1;
    this.outputPath = '';
    this.nativeModuleVersion = '';
    this.progressTimerId = -1;
    this.autoStopTimerId = -1;
    this.progressCallback = null;
    this.stateEvents = [];
    this.errorMessage = '';
    this.terminalStateMessage = '';
    this.hasStartedRecording = false;
    this.resolvedWidth = 0;
    this.resolvedHeight = 0;
    this.nativeStopResult = null;
    this.initStartedAtMs = 0;
    this.initCompletedAtMs = 0;
    this.startRequestedAtMs = 0;
    this.recordingStartedAtMs = 0;
    this.stopRequestedAtMs = 0;
    this.stopCompletedAtMs = 0;
    this.finalizeCompletedAtMs = 0;
  }

  private resetCompletion(): void {
    this.completionPromise = null;
    this.completionResolve = null;
    this.completionReject = null;
  }

  private resolveCompletion(result: RecordingAnalysisResult): void {
    if (this.completionResolve) {
      this.completionResolve(result);
    }
    this.resetCompletion();
  }

  private rejectCompletion(error: Error): void {
    if (this.completionReject) {
      this.completionReject(error);
    }
    this.resetCompletion();
  }

  private containsStateKeyword(keyword: string): boolean {
    return this.stateEvents.some((event) => event.label.includes(keyword));
  }

  private addStateEvent(label: string): void {
    this.stateEvents.push({
      label,
      timestampMs: Date.now()
    });
  }

  private getErrorCode(err: Object): string {
    const businessError = err as BusinessError;
    if (businessError && businessError.code !== undefined) {
      return `${businessError.code}`;
    }
    return 'undefined';
  }

  private getErrorMessage(err: Object): string {
    if (err instanceof Error) {
      return err.message;
    }

    const businessError = err as BusinessError;
    if (businessError && businessError.message) {
      return businessError.message;
    }

    try {
      return JSON.stringify(err);
    } catch (_jsonErr) {
      return 'Unknown error';
    }
  }
}
