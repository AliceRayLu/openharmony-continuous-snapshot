import media from '@ohos.multimedia.media';
import screen from '@ohos.screen';
import display from '@ohos.display';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';

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
  private recorder: media.AVRecorder | null = null;
  private lifecycleState: RecorderLifecycleState = 'idle';
  private outputFile: fs.File | null = null;
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
  private mainScreenId: number = -1;
  private defaultDisplayId: number = -1;
  private virtualScreenId: number = -1;
  private mirrorGroupId: number = -1;

  private initStartedAtMs: number = 0;
  private initCompletedAtMs: number = 0;
  private startRequestedAtMs: number = 0;
  private recordingStartedAtMs: number = 0;
  private stopRequestedAtMs: number = 0;
  private stopCompletedAtMs: number = 0;
  private finalizeCompletedAtMs: number = 0;

  private recorderStateChangeHandler: ((state: media.AVRecorderState, reason: media.StateChangeReason) => void) | null = null;
  private errorHandler: ((error: BusinessError) => void) | null = null;
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
      this.prepareOutputFile();
      this.resolveFrameSize();
      this.logPreparedOutputFile();

      this.lifecycleState = 'initializing';
      this.recorder = await media.createAVRecorder();
      this.registerRecorderCallbacks();

      const config = this.buildRecorderConfig();
      this.logRecorderConfig(config);
      this.initStartedAtMs = Date.now();
      console.info(`[Recorder] Calling prepare() at ${this.initStartedAtMs}`);
      await this.recorder.prepare(config);
      this.initCompletedAtMs = Date.now();
      console.info(`[Recorder] prepare() completed in ${this.initCompletedAtMs - this.initStartedAtMs} ms`);

      const surfaceId = await this.recorder.getInputSurface();
      console.info(`[Recorder] Input surface obtained: ${surfaceId}`);

      await this.createVirtualScreen(surfaceId);

      this.startRequestedAtMs = Date.now();
      console.info(`[Recorder] Starting AVRecorder, path=${this.outputPath}, bitrate=${this.options.videoBitrate}, preset=${this.options.preset}, width=${this.resolvedWidth}, height=${this.resolvedHeight}, mainScreenId=${this.mainScreenId}, virtualScreenId=${this.virtualScreenId}`);
      await this.recorder.start();
      this.recordingStartedAtMs = Date.now();
      this.hasStartedRecording = true;
      this.lifecycleState = 'recording';

      this.startProgressLoop();
      this.armAutoStop();
      console.info(`[Recorder] AVRecorder started to ${this.outputPath}`);
    } catch (err) {
      const error = this.asBusinessError(err);
      const fileInfo = this.describeOutputFileForError();
      this.errorMessage = `Start recording failed: code=${error.code}, message=${error.message}, ${fileInfo}`;
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

  private prepareOutputFile(): void {
    const timestamp = Date.now();
    this.outputPath = `${this.options.outputDir}/screen_record_${timestamp}.mp4`;
    this.outputFile = fs.openSync(this.outputPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
  }

  private resolveFrameSize(): void {
    const defaultDisplay = display.getDefaultDisplaySync();
    this.defaultDisplayId = defaultDisplay.id;
    this.resolvedWidth = this.options.frameWidth ?? defaultDisplay.width;
    this.resolvedHeight = this.options.frameHeight ?? defaultDisplay.height;
  }

  private buildRecorderConfig(): media.AVRecorderConfig {
    return {
      audioSourceType: media.AudioSourceType.AUDIO_SOURCE_TYPE_MIC,
      videoSourceType: media.VideoSourceType.VIDEO_SOURCE_TYPE_SURFACE_YUV,
      profile: {
        audioBitrate: 128000,
        audioChannels: 2,
        audioCodec: media.CodecMimeType.AUDIO_AAC,
        audioSampleRate: 48000,
        fileFormat: media.ContainerFormatType.CFT_MPEG_4,
        videoBitrate: this.options.videoBitrate,
        videoCodec: this.toVideoCodec(this.options.preset),
        videoFrameWidth: this.resolvedWidth,
        videoFrameHeight: this.resolvedHeight,
        videoFrameRate: 60
      },
      url: `fd://${this.outputFile!.fd}`
    };
  }

  private async createVirtualScreen(surfaceId: string): Promise<void> {
    const defaultDisplay = display.getDefaultDisplaySync();
    const density = defaultDisplay.densityDPI;
    console.info(`[VirtualScreen] Creating recorder virtual screen with surfaceId=${surfaceId}`);

    const virtualScreenObj = await screen.createVirtualScreen({
      name: 'ScreenRecorderVirtualScreen',
      width: this.resolvedWidth,
      height: this.resolvedHeight,
      density: density,
      surfaceId: surfaceId
    });

    this.virtualScreenId = virtualScreenObj.id;
    console.info(`[VirtualScreen] Virtual screen created, id=${this.virtualScreenId}, parent=${virtualScreenObj.parent}, sourceMode=${virtualScreenObj.sourceMode}`);

    const allScreens = await screen.getAllScreens();
    const mainScreen = allScreens.find(item => item.sourceMode === screen.ScreenSourceMode.SCREEN_MAIN);
    if (!mainScreen) {
      throw new Error('Main screen not found');
    }

    this.mainScreenId = mainScreen.id;
    this.mirrorGroupId = await screen.makeMirror(this.mainScreenId, [this.virtualScreenId]);
    console.info(`[VirtualScreen] Mirror established, group=${this.mirrorGroupId}, mainScreenId=${this.mainScreenId}, virtualScreenId=${this.virtualScreenId}`);
  }

  private registerRecorderCallbacks(): void {
    if (!this.recorder) {
      return;
    }

    this.recorderStateChangeHandler = (state: media.AVRecorderState, reason: media.StateChangeReason) => {
      this.stateEvents.push({
        label: `STATE_${state}_REASON_${reason}`,
        timestampMs: Date.now()
      });
      console.info(`[Recorder] State changed: state=${state}, reason=${reason}`);
    };

    this.errorHandler = (error: BusinessError) => {
      this.errorMessage = `Recorder error ${error.code}: ${error.message}`;
      console.error(`[Recorder] ${this.errorMessage}`);
      if (this.lifecycleState !== 'stopping' && this.lifecycleState !== 'released') {
        void this.finishRecording('error');
      }
    };

    this.recorder.on('stateChange', this.recorderStateChangeHandler);
    this.recorder.on('error', this.errorHandler);
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
    console.info(`[Recorder] Finishing recording, reason=${reason}`);

    try {
      if (this.recorder && this.hasStartedRecording) {
        this.stopRequestedAtMs = Date.now();
        await this.recorder.stop();
        this.stopCompletedAtMs = Date.now();
      }
    } catch (err) {
      const error = this.asBusinessError(err);
      if (!this.errorMessage) {
        this.errorMessage = `Stop recording failed: code=${error.code}, message=${error.message}`;
      }
    }

    await this.disposeResources();
    const result = await this.buildAnalysisResult();
    this.resolveCompletion(result);
  }

  private async buildAnalysisResult(): Promise<RecordingAnalysisResult> {
    const fileSizeBytes = this.getOutputFileSize();
    const wallClockDurationMs = this.computeWallClockDurationMs();
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
    } else if (durationDriftMs > 1000 || this.containsStateKeyword('error')) {
      status = 'WARNING';
      message = durationDriftMs > 1000
        ? `Recording duration drifted by ${durationDriftMs} ms`
        : 'Recording completed with recorder warnings';
    }

    return {
      status,
      message,
      outputPath: this.outputPath,
      requestedDurationSec: this.options.durationSec,
      wallClockDurationMs,
      metadataDurationMs,
      durationDriftMs,
      fileSizeBytes,
      avgBitrateMbps,
      frameWidth: this.resolvedWidth,
      frameHeight: this.resolvedHeight,
      configuredBitrate: this.options.videoBitrate,
      preset: this.options.preset,
      mimeType: 'video/mp4',
      hasVideo: fileSizeBytes > 0,
      hasAudio: true,
      initTimeMs,
      startLatencyMs,
      stopLatencyMs,
      finalizeTimeMs,
      stateEvents: this.stateEvents.map((event) => `${event.label} @ ${new Date(event.timestampMs).toISOString()}`),
      errorMessage: this.errorMessage
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

  private logPreparedOutputFile(): void {
    if (!this.outputFile) {
      return;
    }

    let size = -1;
    try {
      size = fs.statSync(this.outputPath).size;
    } catch (_err) {}

    console.info(`[Recorder] Output file prepared: path=${this.outputPath}, fd=${this.outputFile.fd}, initialSize=${size}`);
  }

  private logRecorderConfig(config: media.AVRecorderConfig): void {
    console.info(`[Recorder] Config: url=${config.url}, videoSourceType=${config.videoSourceType}, audioSourceType=${config.audioSourceType}, videoBitrate=${config.profile.videoBitrate}, audioBitrate=${config.profile.audioBitrate}, videoCodec=${config.profile.videoCodec}, audioCodec=${config.profile.audioCodec}, fileFormat=${config.profile.fileFormat}, videoFrameRate=${config.profile.videoFrameRate}, width=${config.profile.videoFrameWidth}, height=${config.profile.videoFrameHeight}`);
  }

  private describeOutputFileForError(): string {
    const fd = this.outputFile ? this.outputFile.fd : -1;
    const exists = this.outputPath ? fs.accessSync(this.outputPath) : false;
    let size = -1;

    if (exists) {
      try {
        size = fs.statSync(this.outputPath).size;
      } catch (_err) {}
    }

    return `path=${this.outputPath}, fd=${fd}, fileExists=${exists}, fileSize=${size}, mainScreenId=${this.mainScreenId}, virtualScreenId=${this.virtualScreenId}, defaultDisplayId=${this.defaultDisplayId}`;
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
    await this.destroyVirtualScreen();

    if (this.recorder) {
      this.unregisterRecorderCallbacks();
      try {
        await this.recorder.release();
      } catch (err) {
        const error = this.asBusinessError(err);
        if (!this.errorMessage) {
          this.errorMessage = `Release recorder failed: code=${error.code}, message=${error.message}`;
        }
      }
      this.recorder = null;
    }

    if (this.outputFile) {
      try {
        fs.closeSync(this.outputFile);
      } catch (_err) {}
      this.outputFile = null;
    }

    this.finalizeCompletedAtMs = Date.now();
    this.lifecycleState = 'released';
  }

  private async destroyVirtualScreen(): Promise<void> {
    if (this.virtualScreenId === -1) {
      return;
    }

    try {
      if (this.mirrorGroupId !== -1) {
        await screen.stopMirror([this.virtualScreenId]);
        console.info('[VirtualScreen] Mirror stopped');
        this.mirrorGroupId = -1;
      }
    } catch (err) {
      const error = this.asBusinessError(err);
      console.warn(`[VirtualScreen] stopMirror failed: code=${error.code}, message=${error.message}`);
    }

    try {
      await screen.destroyVirtualScreen(this.virtualScreenId);
      console.info(`[VirtualScreen] Virtual screen destroyed: ${this.virtualScreenId}`);
    } catch (err) {
      const error = this.asBusinessError(err);
      console.warn(`[VirtualScreen] destroyVirtualScreen failed: code=${error.code}, message=${error.message}`);
    }

    this.virtualScreenId = -1;
  }

  private unregisterRecorderCallbacks(): void {
    if (!this.recorder) {
      return;
    }

    if (this.recorderStateChangeHandler) {
      this.recorder.off('stateChange', this.recorderStateChangeHandler);
      this.recorderStateChangeHandler = null;
    }

    if (this.errorHandler) {
      this.recorder.off('error', this.errorHandler);
      this.errorHandler = null;
    }
  }

  private resetRunState(): void {
    this.lifecycleState = 'idle';
    this.outputPath = '';
    this.outputFile = null;
    this.progressTimerId = -1;
    this.autoStopTimerId = -1;
    this.progressCallback = null;
    this.stateEvents = [];
    this.errorMessage = '';
    this.terminalStateMessage = '';
    this.hasStartedRecording = false;
    this.resolvedWidth = 0;
    this.resolvedHeight = 0;
    this.mainScreenId = -1;
    this.defaultDisplayId = -1;
    this.virtualScreenId = -1;
    this.mirrorGroupId = -1;
    this.initStartedAtMs = 0;
    this.initCompletedAtMs = 0;
    this.startRequestedAtMs = 0;
    this.recordingStartedAtMs = 0;
    this.stopRequestedAtMs = 0;
    this.stopCompletedAtMs = 0;
    this.finalizeCompletedAtMs = 0;
    this.recorderStateChangeHandler = null;
    this.errorHandler = null;
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

  private toVideoCodec(preset: RecordingPreset): media.CodecMimeType {
    return preset === 'H265'
      ? media.CodecMimeType.VIDEO_HEVC
      : media.CodecMimeType.VIDEO_AVC;
  }

  private asBusinessError(err: Object): BusinessError {
    return err as BusinessError;
  }
}
