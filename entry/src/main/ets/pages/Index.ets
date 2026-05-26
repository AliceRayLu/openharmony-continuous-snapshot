import { VirtualScreenManager, ScreenshotOptions, AnalysisResult } from '../utils/VirtualScreenManager';
import display from '@ohos.display';
import fs from '@ohos.file.fs';

@Entry
@Component
struct Index {
  @State captureStatus: string = 'Idle';
  @State progress: number = 0;
  @State resultMessage: string = '';
  @State isCapturing: boolean = false;
  @State captureBtnText: string = 'Start Capture';
  @State intervalMs: number = 100;      // 截图间隔（毫秒）
  @State durationSec: number = 5;        // 持续时间（秒）
  @State virtualScreenId: string = 'Not created';
  @State canExportReport: boolean = false;

  private readonly outputDir: string = '/data/storage/el2/base/haps/entry/files/screenshots';
  private screenManager: VirtualScreenManager | null = null;
  private analysisResult: AnalysisResult | null = null;
  private lastCaptureIntervalMs: number = 100;
  private lastCaptureDurationSec: number = 5;

  aboutToAppear() {
    this.initVirtualScreen();
  }

  async aboutToDisappear() {
    if (this.screenManager) {
      await this.screenManager.cleanup();
    }
  }

  async initVirtualScreen() {
    try {
      this.captureStatus = 'Creating virtual screen...';

      if (this.screenManager) {
        await this.screenManager.cleanup();
        this.screenManager = null;
      }

      const defaultDisplay = display.getDefaultDisplaySync();
      this.screenManager = new VirtualScreenManager({
        intervalMs: this.intervalMs,
        durationSec: this.durationSec,
        outputDir: this.outputDir
      });

      if (!fs.accessSync(this.outputDir)) {
        fs.mkdirSync(this.outputDir);
      }

      const screenId = await this.screenManager.createVirtualScreen(
        defaultDisplay.width,
        defaultDisplay.height
      );
      this.virtualScreenId = screenId.toString();
      this.captureStatus = `Virtual screen ready (${this.durationSec}s @ ${Math.round(1000 / this.intervalMs)}fps)`;
    } catch (err) {
      this.captureStatus = `Init failed: ${err.message}`;
    }
  }

  async startCapture() {
    if (this.isCapturing) return;

    this.isCapturing = true;
    this.captureBtnText = 'Preparing...';
    this.progress = 0;
    this.resultMessage = '';
    this.canExportReport = false;

    try {
      await this.initVirtualScreen();
      if (!this.screenManager) {
        throw new Error('Virtual screen manager is unavailable');
      }

      this.lastCaptureIntervalMs = this.intervalMs;
      this.lastCaptureDurationSec = this.durationSec;
      this.captureBtnText = 'Capturing...';

      await this.screenManager.startContinuousCapture((progress) => {
        this.progress = progress;
        this.captureStatus = `Capturing: ${Math.floor(progress * 100)}%`;
      });

      this.analysisResult = await this.screenManager.analyzeFrameRate();
      this.canExportReport = true;
      this.displayAnalysisResult();

      this.captureStatus = 'Capture completed';
    } catch (err) {
      this.captureStatus = `Capture failed: ${err.message}`;
      this.resultMessage = `Error: ${err.message}`;
    } finally {
      this.isCapturing = false;
      this.captureBtnText = 'Start Capture';
    }
  }

  displayAnalysisResult() {
    if (!this.analysisResult) return;

    this.resultMessage = `
═══════════════════════════════════════
          FRAME RATE ANALYSIS
═══════════════════════════════════════
Status: ${this.analysisResult.status}
Message: ${this.analysisResult.message}

Metrics:
  ├─ Total frames captured: ${this.analysisResult.totalFrames}
  ├─ Expected frame rate: ${this.analysisResult.expectedFps} fps
  ├─ Actual frame rate: ${this.analysisResult.actualFps.toFixed(2)} fps
  ├─ Frame drop rate: ${(this.analysisResult.frameDropRate * 100).toFixed(2)}%
  ├─ Avg capture time: ${this.analysisResult.avgCaptureTimeMs.toFixed(2)} ms
  └─ Max capture time: ${this.analysisResult.maxCaptureTimeMs.toFixed(2)} ms

Abnormal frames: ${this.analysisResult.abnormalTimestamps.length}
═══════════════════════════════════════
    `;
  }

  async exportReport() {
    if (!this.analysisResult) return;

    const reportPath = '/data/storage/el2/base/haps/entry/files/report.txt';
    const reportContent = `
Continuous Screenshot Performance Report
Generated: ${new Date().toISOString()}
─────────────────────────────────────────
Configuration:
  Screenshot interval: ${this.lastCaptureIntervalMs} ms
  Duration: ${this.lastCaptureDurationSec} s

Results:
  Status: ${this.analysisResult.status}
  Total Frames: ${this.analysisResult.totalFrames}
  Expected FPS: ${this.analysisResult.expectedFps}
  Actual FPS: ${this.analysisResult.actualFps.toFixed(2)}
  Frame Drop Rate: ${(this.analysisResult.frameDropRate * 100).toFixed(2)}%
  Avg Capture Time: ${this.analysisResult.avgCaptureTimeMs.toFixed(2)} ms
  Max Capture Time: ${this.analysisResult.maxCaptureTimeMs.toFixed(2)} ms

Message: ${this.analysisResult.message}
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

  build() {
    Column() {
      // 标题栏
      Row() {
        Text('Continuous Screenshot Tool')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 16 })
      }
      .width('100%')
      .height(56)
      .backgroundColor('#F1F3F5')

      Scroll() {
        Column({ space: 16 }) {
          // 配置面板
          Column() {
            Text('Configuration')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .margin({ bottom: 12 })

            Row() {
              Text('Interval (ms):')
                .width(120)
              Slider({
                value: this.intervalMs,
                min: 16,
                max: 500,
                step: 1
              })
                .layoutWeight(1)
                .onChange((value) => {
                  this.intervalMs = value;
                })
              Text(`${this.intervalMs}ms → ${Math.round(1000 / this.intervalMs)}fps`)
                .width(100)
                .fontSize(12)
            }
            .width('100%')
            .margin({ bottom: 12 })

            Row() {
              Text('Duration (s):')
                .width(120)
              Slider({
                value: this.durationSec,
                min: 1,
                max: 30,
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
          }
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(12)

          // 状态面板
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
              Text(`Virtual Screen ID: ${this.virtualScreenId}`)
                .fontSize(12)
                .fontColor('#999999')
            }
            .margin({ top: 8 })
          }
          .padding(16)
          .backgroundColor('#FFFFFF')
          .borderRadius(12)

          // 控制按钮
          Row({ space: 16 }) {
            Button(this.captureBtnText)
              .fontSize(16)
              .height(48)
              .layoutWeight(1)
              .enabled(!this.isCapturing)
              .onClick(() => this.startCapture())

            Button('Export Report')
              .fontSize(16)
              .height(48)
              .layoutWeight(1)
              .enabled(this.canExportReport)
              .onClick(() => this.exportReport())
          }
          .width('100%')

          // 分析结果
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