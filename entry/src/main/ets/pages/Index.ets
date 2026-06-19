import { ScreenRecorderManager, RecordingAnalysisResult, RecordingPreset } from '../utils/ScreenRecorderManager';
import fs from '@ohos.file.fs';
import abilityAccessCtrl, { Permissions } from '@ohos.abilityAccessCtrl';

@Entry
@Component
struct Index {
  @State captureStatus: string = 'Idle';
  @State progress: number = 0;
  @State resultMessage: string = '';
  @State isCapturing: boolean = false;
  @State captureBtnText: string = 'Start Recording';
  @State durationSec: number = 5;
  @State videoBitrateMbps: number = 8;
  @State recordPreset: RecordingPreset = 'H264';
  @State canExportReport: boolean = false;

  private outputDir: string = '/data/storage/el2/base/haps/entry/files/recordings';
  private screenRecorder: ScreenRecorderManager | null = null;
  private analysisResult: RecordingAnalysisResult | null = null;
  private lastCaptureDurationSec: number = 5;
  private lastVideoBitrate: number = 8_000_000;
  private lastRecordPreset: RecordingPreset = 'H264';

  async aboutToDisappear() {
    if (this.screenRecorder) {
      await this.screenRecorder.cleanup();
      this.screenRecorder = null;
    }
  }

  async startRecording() {
    if (this.isCapturing) return;

    await this.ensureRecordingPermission();

    this.isCapturing = true;
    this.captureBtnText = 'Recording...';
    this.progress = 0;
    this.resultMessage = '';
    this.canExportReport = false;
    this.captureStatus = 'Preparing recorder...';

    try {
      const uiContext = this.getUIContext();
      const hostContext = uiContext.getHostContext();
      if (!hostContext) {
        throw new Error('UI host context is unavailable');
      }
      this.outputDir = `${hostContext.filesDir}/recordings`;

      if (!fs.accessSync(this.outputDir)) {
        fs.mkdirSync(this.outputDir, true);
      }
      console.info(`[Index] Recording output directory: ${this.outputDir}`);

      if (this.screenRecorder) {
        await this.screenRecorder.cleanup();
      }

      this.lastCaptureDurationSec = this.durationSec;
      this.lastVideoBitrate = this.videoBitrateMbps * 1_000_000;
      this.lastRecordPreset = this.recordPreset;

      this.screenRecorder = new ScreenRecorderManager({
        durationSec: this.durationSec,
        outputDir: this.outputDir,
        videoBitrate: this.lastVideoBitrate,
        preset: this.recordPreset,
        micEnabled: false
      });

      this.analysisResult = await this.screenRecorder.startRecording((progress) => {
        this.progress = progress;
        this.captureStatus = `Recording: ${Math.floor(progress * 100)}%`;
      });

      if (!this.analysisResult) {
        throw new Error('Recording finished without analysis result');
      }

      this.progress = 1;
      this.canExportReport = true;
      this.displayAnalysisResult();
      this.captureStatus = this.analysisResult.status === 'ABNORMAL'
        ? 'Recording finished with errors'
        : 'Recording completed';
    } catch (err) {
      this.captureStatus = `Recording failed: ${err.message}`;
      this.resultMessage = `Error: ${err.message}`;
    } finally {
      if (this.screenRecorder) {
        await this.screenRecorder.cleanup();
        this.screenRecorder = null;
      }
      this.isCapturing = false;
      this.captureBtnText = 'Start Recording';
    }
  }

  displayAnalysisResult() {
    if (!this.analysisResult) return;

    const metadataDurationText = this.analysisResult.metadataDurationMs > 0
      ? `${this.analysisResult.metadataDurationMs} ms`
      : 'Unavailable';
    const eventText = this.analysisResult.stateEvents.length > 0
      ? this.analysisResult.stateEvents.join('\n      ')
      : 'None';

    this.resultMessage = `
═══════════════════════════════════════
          RECORDING ANALYSIS
═══════════════════════════════════════
Status: ${this.analysisResult.status}
Message: ${this.analysisResult.message}
Error detail: ${this.analysisResult.errorMessage || 'None'}

Configuration:
  ├─ Duration: ${this.lastCaptureDurationSec} s
  ├─ Preset: ${this.lastRecordPreset}
  └─ Video bitrate: ${this.videoBitrateMbps} Mbps

Output:
  ├─ Path: ${this.analysisResult.outputPath}
  ├─ File size: ${this.formatFileSize(this.analysisResult.fileSizeBytes)}
  ├─ Mime type: ${this.analysisResult.mimeType}
  ├─ Has video: ${this.analysisResult.hasVideo}
  ├─ Has audio: ${this.analysisResult.hasAudio}
  └─ Resolution: ${this.analysisResult.frameWidth}x${this.analysisResult.frameHeight}

Timing:
  ├─ Requested duration: ${this.analysisResult.requestedDurationSec}s
  ├─ Wall-clock duration: ${this.analysisResult.wallClockDurationMs} ms
  ├─ Metadata duration: ${metadataDurationText}
  ├─ Duration drift: ${this.analysisResult.durationDriftMs} ms
  ├─ Init time: ${this.analysisResult.initTimeMs} ms
  ├─ Start latency: ${this.analysisResult.startLatencyMs} ms
  ├─ Stop latency: ${this.analysisResult.stopLatencyMs} ms
  ├─ Finalize time: ${this.analysisResult.finalizeTimeMs} ms
  └─ Avg produced bitrate: ${this.analysisResult.avgBitrateMbps.toFixed(2)} Mbps

State events:
      ${eventText}
═══════════════════════════════════════
    `;
  }

  private async ensureRecordingPermission(): Promise<void> {
    const permissions: Permissions[] = [
      'ohos.permission.CAPTURE_SCREEN',
      'ohos.permission.MICROPHONE'
    ];
    const uiContext = this.getUIContext();
    const hostContext = uiContext.getHostContext();

    if (!hostContext) {
      throw new Error('UI host context is unavailable');
    }

    const atManager = abilityAccessCtrl.createAtManager();
    const result = await atManager.requestPermissionsFromUser(hostContext, permissions);
    const authResults = result.authResults ?? [];
    const deniedIndex = authResults.findIndex((status) => status !== 0);

    if (deniedIndex !== -1) {
      throw new Error(`Permission was denied: ${permissions[deniedIndex]}`);
    }
  }

  async exportReport() {
    if (!this.analysisResult) return;

    const reportPath = '/data/storage/el2/base/haps/entry/files/recording_report.txt';
    const reportContent = `
Screen Recording Performance Report
Generated: ${new Date().toISOString()}
─────────────────────────────────────────
Configuration:
  Duration: ${this.lastCaptureDurationSec} s
  Preset: ${this.lastRecordPreset}
  Video bitrate: ${this.videoBitrateMbps} Mbps

Results:
  Status: ${this.analysisResult.status}
  Message: ${this.analysisResult.message}
  Error detail: ${this.analysisResult.errorMessage || 'None'}
  Output path: ${this.analysisResult.outputPath}
  File size: ${this.analysisResult.fileSizeBytes} bytes
  Mime type: ${this.analysisResult.mimeType}
  Has video: ${this.analysisResult.hasVideo}
  Has audio: ${this.analysisResult.hasAudio}
  Resolution: ${this.analysisResult.frameWidth}x${this.analysisResult.frameHeight}
  Requested duration: ${this.analysisResult.requestedDurationSec} s
  Wall-clock duration: ${this.analysisResult.wallClockDurationMs} ms
  Metadata duration: ${this.analysisResult.metadataDurationMs} ms
  Duration drift: ${this.analysisResult.durationDriftMs} ms
  Init time: ${this.analysisResult.initTimeMs} ms
  Start latency: ${this.analysisResult.startLatencyMs} ms
  Stop latency: ${this.analysisResult.stopLatencyMs} ms
  Finalize time: ${this.analysisResult.finalizeTimeMs} ms
  Average produced bitrate: ${this.analysisResult.avgBitrateMbps.toFixed(2)} Mbps

State events:
  ${this.analysisResult.stateEvents.join('\n  ')}
    `;

    try {
      const file = fs.openSync(reportPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      fs.writeSync(file.fd, reportContent);
      fs.closeSync(file);
      this.resultMessage += `\nReport saved to: ${reportPath}`;
    } catch (err) {
      console.error('Export failed:', err);
    }
  }

  private formatFileSize(sizeBytes: number): string {
    if (sizeBytes >= 1024 * 1024) {
      return `${(sizeBytes / (1024 * 1024)).toFixed(2)} MB`;
    }
    if (sizeBytes >= 1024) {
      return `${(sizeBytes / 1024).toFixed(2)} KB`;
    }
    return `${sizeBytes} B`;
  }

  build() {
    Column() {
      Row() {
        Text('Screen Recording Tool')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 16 })
      }
      .width('100%')
      .height(56)
      .backgroundColor('#F1F3F5')

      Scroll() {
        Column({ space: 16 }) {
          Column() {
            Text('Configuration')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 12 })

            Row() {
              Text('Duration (s):')
                .width(120)
              Slider({
                value: this.durationSec,
                min: 1,
                max: 120,
                step: 1
              })
                .layoutWeight(1)
                .onChange((value) => {
                  this.durationSec = value;
                })
              Text(`${this.durationSec}s`)
                .width(60)
                .fontSize(12)
            }
            .width('100%')
            .margin({ bottom: 12 })

            Row() {
              Text('Bitrate (Mbps):')
                .width(120)
              Slider({
                value: this.videoBitrateMbps,
                min: 2,
                max: 20,
                step: 1
              })
                .layoutWeight(1)
                .onChange((value) => {
                  this.videoBitrateMbps = value;
                })
              Text(`${this.videoBitrateMbps} Mbps`)
                .width(80)
                .fontSize(12)
            }
            .width('100%')
            .margin({ bottom: 12 })

            Row({ space: 12 }) {
              Text('Preset:')
                .width(120)
              Button(this.recordPreset === 'H264' ? '● H.264 MP4' : '○ H.264 MP4')
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .onClick(() => {
                  this.recordPreset = 'H264';
                })
              Button(this.recordPreset === 'H265' ? '● H.265 MP4' : '○ H.265 MP4')
                .type(ButtonType.Normal)
                .layoutWeight(1)
                .onClick(() => {
                  this.recordPreset = 'H265';
                })
            }
            .width('100%')
          }
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(12)

          Column() {
            Text('Status')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 8 })

            Text(this.captureStatus)
              .fontSize(14)
              .fontColor('#666666')
              .margin({ bottom: 8 })

            if (this.progress > 0 && this.progress < 1) {
              Progress({ value: this.progress * 100, total: 100, type: ProgressType.Linear })
                .width('100%')
                .height(8)
            }

            Row() {
              Text(`Output directory: ${this.outputDir}`)
                .fontSize(12)
                .fontColor('#999999')
            }
            .margin({ top: 8 })
          }
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(12)

          Row({ space: 16 }) {
            Button(this.captureBtnText)
              .fontSize(16)
              .height(48)
              .layoutWeight(1)
              .enabled(!this.isCapturing)
              .onClick(() => this.startRecording())

            Button('Export Report')
              .fontSize(16)
              .height(48)
              .layoutWeight(1)
              .enabled(this.canExportReport)
              .onClick(() => this.exportReport())
          }
          .width('100%')

          if (this.resultMessage) {
            Column() {
              Text('Analysis Result')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .margin({ bottom: 8 })

              Text(this.resultMessage)
                .fontSize(12)
                .fontFamily('monospace')
                .fontColor('#333333')
                .width('100%')
                .padding(12)
                .backgroundColor('#F8F9FA')
                .borderRadius(8)
            }
            .padding(16)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
          }
        }
        .padding(16)
      }
      .layoutWeight(1)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
