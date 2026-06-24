// VirtualScreenManager.ets
import screen from '@ohos.screen';
import display from '@ohos.display';
import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';

export type CaptureFormat = 'JPEG';

export interface ScreenshotOptions {
  intervalMs: number;      // 截图间隔（毫秒）
  durationSec: number;     // 总持续时间（秒）
  outputDir: string;       // 输出目录
  captureFormat: CaptureFormat;
  pixelThreshold?: number; // 帧差异阈值（默认0.95）
}

interface FrameBufferEntry {
  format: CaptureFormat;
  buffers: ArrayBuffer[];
}

interface PendingImageEntry {
  img: image.Image;
  readCostMs: number;
  queuedAt: number;
  source: string;
  estimatedSkippedBefore: number;
}

export interface FrameData {
  index: number;
  timestamp: number;       // 时间戳（纳秒）
  path: string;            // 文件保存路径
  hash: string;            // 图像哈希（用于快速比对）
  width: number;
  height: number;
}

export interface AnalysisResult {
  totalFrames: number;
  expectedFps: number;           // 理论帧率 = 1000 / intervalMs
  actualFps: number;             // 实际帧率
  frameDropRate: number;         // 丢帧率
  avgCaptureTimeMs: number;      // 平均截图耗时（毫秒）
  maxCaptureTimeMs: number;      // 最大截图耗时（毫秒）
  abnormalTimestamps: number[];  // 异常帧时间点
  status: 'NORMAL' | 'WARNING' | 'ABNORMAL';
  message: string;
}

export class VirtualScreenManager {
  private static readonly RECEIVER_CAPACITY: number = 10;
  private static readonly WAIT_DRAIN_INTERVAL_MS: number = 16;

  private virtualScreenId: number = -1;
  private mirrorGroupId: number = -1;
  private mainScreenId: number = -1;
  private defaultDisplayId: number = -1;
  private isCapturing: boolean = false;
  private timerId: number = -1;
  private frameList: FrameData[] = [];
  private options: ScreenshotOptions;
  private captureStartTime: number = 0;
  private lastCaptureTime: number = 0;
  private captureTimes: number[] = [];
  private imageReceiver: image.ImageReceiver | null = null;
  private frameBuffers: FrameBufferEntry[] = [];
  private resolvedCaptureWidth: number = 0;
  private resolvedCaptureHeight: number = 0;
  private latestPendingImage: PendingImageEntry | null = null;
  private processingImage: PendingImageEntry | null = null;
  private processingFrame: boolean = false;
  private receiverReading: boolean = false;
  private stoppingCapture: boolean = false;
  private frameIndex: number = 0;
  private totalFrames: number = 0;
  private discardedImageCount: number = 0;
  private resolveCapture: ((frames: FrameData[]) => void) | null = null;
  private onProgressCallback: ((progress: number) => void) | undefined = undefined;

  constructor(options: ScreenshotOptions) {
    this.options = options;
  }

  /**
   * 获取默认主屏 ID
   */
  private async getDefaultMainScreenId(): Promise<number> {
    try {
      const allScreens = await screen.getAllScreens();
      const mainScreen = allScreens.find(s => s.sourceMode === screen.ScreenSourceMode.SCREEN_MAIN);
      if (mainScreen) {
        return mainScreen.id;
      }
      if (allScreens.length > 0) {
        return allScreens[0].id;
      }
      throw new Error('No screen available');
    } catch (err) {
      let error = err as BusinessError;
      console.error(`[VirtualScreen] Get main screen failed: ${error.code} - ${error.message}`);
      throw new Error('Failed to get main screen');
    }
  }

  /**
   * 创建虚拟屏幕并设置镜像
   */
  async createVirtualScreen(width?: number, height?: number): Promise<number> {
    if (this.virtualScreenId !== -1) {
      console.warn('[VirtualScreen] Virtual screen already exists');
      return this.virtualScreenId;
    }

    try {
      const defaultDisplay = display.getDefaultDisplaySync();
      this.defaultDisplayId = defaultDisplay.id;
      const screenWidth = width ?? defaultDisplay.width;
      const screenHeight = height ?? defaultDisplay.height;
      this.resolvedCaptureWidth = screenWidth;
      this.resolvedCaptureHeight = screenHeight;
      const density = defaultDisplay.densityDPI;
      console.info(`[VirtualScreen] Default display id=${defaultDisplay.id}, width=${defaultDisplay.width}, height=${defaultDisplay.height}, density=${defaultDisplay.densityDPI}`);

      const virtualScreenObj = await screen.createVirtualScreen({
        name: 'ContinuousScreenshotVirtualScreen',
        width: screenWidth,
        height: screenHeight,
        density: density,
        surfaceId: ''
      });

      this.virtualScreenId = virtualScreenObj.id;
      console.info(`[VirtualScreen] Virtual screen created, ID: ${this.virtualScreenId}, parent=${virtualScreenObj.parent}, sourceMode=${virtualScreenObj.sourceMode}`);

      const mainScreenId = await this.getDefaultMainScreenId();
      this.mainScreenId = mainScreenId;
      console.info(`[VirtualScreen] Preparing mirror, mainScreenId=${mainScreenId}, virtualScreenId=${this.virtualScreenId}, defaultDisplayId=${this.defaultDisplayId}`);
      this.mirrorGroupId = await screen.makeMirror(mainScreenId, [this.virtualScreenId]);
      console.info(`[VirtualScreen] Mirror set, group ID: ${this.mirrorGroupId}, mainScreenId=${mainScreenId}, virtualScreenId=${this.virtualScreenId}`);

      return this.virtualScreenId;
    } catch (err) {
      let error = err as BusinessError;
      console.error(`[VirtualScreen] Create/mirror failed: ${error.code} - ${error.message}`);
      throw new Error(`Failed to create virtual screen: ${error.message}`);
    }
  }

  /**
   * 销毁虚拟屏幕
   */
  async destroyVirtualScreen(): Promise<void> {
    if (this.virtualScreenId === -1) return;

    try {
      if (this.imageReceiver) {
        await this.imageReceiver.release();
        this.imageReceiver = null;
        console.info('[VirtualScreen] ImageReceiver released');
      }
      if (this.mirrorGroupId !== -1) {
        await screen.stopMirror([this.virtualScreenId]);
        console.info('[VirtualScreen] Mirror stopped');
        this.mirrorGroupId = -1;
      }
      await screen.destroyVirtualScreen(this.virtualScreenId);
      this.virtualScreenId = -1;
      console.info('[VirtualScreen] Virtual screen destroyed');
    } catch (err) {
      let error = err as BusinessError;
      console.error(`[VirtualScreen] Destroy failed: ${error.code} - ${error.message}`);
      throw new Error(`Failed to destroy virtual screen: ${error.message}`);
    }
  }

  /**
   * 开始连续截图
   */
  async startContinuousCapture(onProgress?: (progress: number) => void): Promise<FrameData[]> {
    if (this.isCapturing) {
      throw new Error('Capture already in progress');
    }
    if (this.virtualScreenId === -1) {
      throw new Error('Virtual screen not created, call createVirtualScreen first');
    }

    this.frameList = [];
    this.frameBuffers = [];
    this.captureTimes = [];
    this.lastCaptureTime = 0;
    this.latestPendingImage = null;
    this.processingImage = null;
    this.processingFrame = false;
    this.receiverReading = false;
    this.stoppingCapture = false;
    this.frameIndex = 0;
    this.discardedImageCount = 0;
    this.onProgressCallback = onProgress;
    this.totalFrames = Math.ceil((this.options.durationSec * 1000) / this.options.intervalMs);
    this.isCapturing = true;

    // 创建 ImageReceiver 并绑定虚拟屏 surface，仅在截图期间开启
    this.imageReceiver = image.createImageReceiver(
      { width: this.resolvedCaptureWidth, height: this.resolvedCaptureHeight },
      image.ImageFormat.JPEG,
      VirtualScreenManager.RECEIVER_CAPACITY
    );
    console.info(`[Capture] ImageReceiver created, size=${this.resolvedCaptureWidth}x${this.resolvedCaptureHeight}, format=${this.options.captureFormat}, capacity=${VirtualScreenManager.RECEIVER_CAPACITY}, drainApi=readLatestImage`);

    const surfaceId = await this.imageReceiver.getReceivingSurfaceId();
    console.info(`[Capture] ImageReceiver surfaceId: ${surfaceId}`);

    await screen.setVirtualScreenSurface(this.virtualScreenId, surfaceId);
    console.info(`[Capture] Surface bound to virtual screen`);

    // 在此之后才开始计时，不把 setup 耗时算入帧率
    this.captureStartTime = Date.now();
    this.lastCaptureTime = this.captureStartTime - this.options.intervalMs;

    console.info(`[Capture] Starting continuous capture, target ${this.totalFrames} frames, intervalMs=${this.options.intervalMs}, durationSec=${this.options.durationSec}, outputDir=${this.options.outputDir}, virtualScreenId=${this.virtualScreenId}, mainScreenId=${this.mainScreenId}, defaultDisplayId=${this.defaultDisplayId}`);

    return new Promise((resolve) => {
      this.resolveCapture = resolve;
      this.captureLoop();
    });
  }

  /**
   * 停止连续截图
   */
  async stopContinuousCapture(): Promise<void> {
    if (this.stoppingCapture) {
      return;
    }
    if (!this.isCapturing && this.resolveCapture === null) {
      return;
    }

    this.stoppingCapture = true;

    if (this.timerId !== -1) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
    this.isCapturing = false;

    await this.waitForProcessingIdle();
    await this.releasePendingImages('stop');
    await this.flushFrameBuffers();

    if (this.imageReceiver) {
      await this.imageReceiver.release();
      this.imageReceiver = null;
      console.info('[Capture] ImageReceiver released');
    }

    const resolve = this.resolveCapture;
    this.resolveCapture = null;
    this.onProgressCallback = undefined;
    console.info(`[Capture] Stopped, captured ${this.frameList.length} frames, discardedImages=${this.discardedImageCount}`);
    if (resolve) {
      resolve(this.frameList);
    }
  }

  private async captureLoop(): Promise<void> {
    this.processingFrame = true;
    try {
      await this.updateLatestPendingImage('initial');

      while (this.isCapturing) {
        if (Date.now() - this.captureStartTime >= this.options.durationSec * 1000) {
          break;
        }

        await this.updateLatestPendingImage('beforeWait');
        const now = Date.now();
        const elapsedSinceLastCapture = now - this.lastCaptureTime;
        if (elapsedSinceLastCapture < this.options.intervalMs) {
          const sleepMs = Math.min(
            VirtualScreenManager.WAIT_DRAIN_INTERVAL_MS,
            this.options.intervalMs - elapsedSinceLastCapture
          );
          await this.sleep(Math.max(1, sleepMs));
          continue;
        }

        if (this.latestPendingImage === null) {
          await this.updateLatestPendingImage('empty');
          if (this.latestPendingImage === null) {
            await this.sleep(5);
            continue;
          }
        }

        const entry = this.takeLatestPendingImage();
        if (!entry) {
          continue;
        }

        this.processingImage = entry;
        const frameStart = Date.now();
        try {
          const frameData = await this.captureSingleFrame(entry, this.frameIndex);
          frameData.index = this.frameIndex;
          this.frameList.push(frameData);
          this.captureTimes.push(Date.now() - frameStart);
          this.lastCaptureTime = Date.now();

          this.frameIndex++;
          if (this.onProgressCallback) {
            this.onProgressCallback(Math.min(this.frameIndex / this.totalFrames, 1));
          }
        } catch (err) {
          let error = err as BusinessError;
          console.error(`[Capture] Frame ${this.frameIndex} failed: code=${error.code}, message=${error.message}`);
          this.lastCaptureTime = Date.now();
        } finally {
          await this.releasePendingImage(entry, 'processed');
          this.processingImage = null;
        }

      }
    } finally {
      this.processingFrame = false;
      await this.stopContinuousCapture();
    }
  }

  private takeLatestPendingImage(): PendingImageEntry | null {
    const entry = this.latestPendingImage;
    this.latestPendingImage = null;
    return entry;
  }

  private async updateLatestPendingImage(source: string): Promise<void> {
    if (!this.isCapturing || !this.imageReceiver || this.receiverReading) {
      return;
    }

    this.receiverReading = true;
    let img: image.Image | null = null;
    let releasedCount = 0;
    let readCount = 0;
    const drainStart = Date.now();
    try {
      const oldEntry = this.latestPendingImage;
      if (oldEntry) {
        this.latestPendingImage = null;
        await this.releasePendingImage(oldEntry, 'replace latest before read');
        this.discardedImageCount++;
        releasedCount++;
      }

      const readStart = Date.now();
      img = await this.imageReceiver.readLatestImage();
      const readCostMs = Date.now() - readStart;
      const queuedAt = Date.now();
      readCount = 1;

      this.latestPendingImage = {
        img: img,
        readCostMs: readCostMs,
        queuedAt: queuedAt,
        source: source,
        estimatedSkippedBefore: 0
      };
      img = null;
    } catch (_) {
      if (img) {
        try {
          await img.release();
        } catch (_) {
        }
      }
    } finally {
      this.receiverReading = false;
    }

    if (readCount > 0 || releasedCount > 0) {
      console.info(`[Drain] source=${source}, api=readLatestImage, read=${readCount}, released=${releasedCount}, pending=${this.latestPendingImage ? 1 : 0}, discardedImages=${this.discardedImageCount}, cost=${Date.now() - drainStart}ms`);
    }
  }

  private async releasePendingImage(entry: PendingImageEntry | undefined, reason: string): Promise<void> {
    if (!entry) {
      return;
    }
    if (this.processingImage === entry && reason !== 'processed') {
      console.warn(`[Capture] Skip release processing image, reason=${reason}`);
      return;
    }

    try {
      await entry.img.release();
    } catch (err) {
      let error = err as BusinessError;
      console.warn(`[Capture] Release image failed, reason=${reason}, code=${error.code}, message=${error.message}`);
    }
  }

  private async releasePendingImages(reason: string): Promise<void> {
    const entry = this.latestPendingImage;
    this.latestPendingImage = null;
    if (!entry || entry === this.processingImage) {
      return;
    }
    await this.releasePendingImage(entry, reason);
    this.discardedImageCount++;
  }

  private async waitForProcessingIdle(): Promise<void> {
    while (this.processingFrame || this.receiverReading) {
      await this.sleep(10);
    }
  }

  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => setTimeout(resolve, ms));
  }

  /**
   * 单帧截图 - 处理已经从 ImageReceiver 读出的 Image
   * 帧数据先缓存到内存，截图结束后统一写盘
   */
  private async captureSingleFrame(entry: PendingImageEntry, frameIndex: number): Promise<FrameData> {
    const t0 = Date.now();
    const timestamp = Date.now() * 1000000;
    const outputPath = `${this.options.outputDir}/frame_${timestamp}.jpg`;

    try {
      const captureWidth = this.resolvedCaptureWidth;
      const captureHeight = this.resolvedCaptureHeight;

      const img = entry.img;
      const componentStart = Date.now();
      const component = await img.getComponent(image.ComponentType.JPEG);
      const componentEnd = Date.now();

      const copyStart = Date.now();
      const frameCopy = component.byteBuffer.slice(0);
      this.frameBuffers.push({ format: 'JPEG', buffers: [frameCopy] });
      const copyEnd = Date.now();

      const elapsed = copyEnd - t0;
      console.info(`[Capture] Frame ${frameIndex}: source=${entry.source}, mode=JPEG, img.format=${img.format}, img.size=${img.size.width}x${img.size.height}, size=${component.byteBuffer.byteLength}, rowStride=${component.rowStride}, pixelStride=${component.pixelStride}, readLatest=${entry.readCostMs}ms, queueWait=${t0 - entry.queuedAt}ms, getComponent=${componentEnd - componentStart}ms, copy=${copyEnd - copyStart}ms, total=${elapsed}ms, pending=${this.latestPendingImage ? 1 : 0}, discardedImages=${this.discardedImageCount}`);

      return {
        index: frameIndex,
        timestamp: timestamp,
        path: outputPath,
        hash: `${Date.now()}_${Math.random()}`,
        width: captureWidth,
        height: captureHeight
      };
    } catch (err) {
      let error = err as BusinessError;
      console.error(`[Capture] Frame ${frameIndex} capture failed, code=${error.code}, message=${error.message}`);
      throw new Error(`Capture failed: ${error.message}`);
    }
  }

  /**
   * 按 JPEG 接收格式批量写盘：直接写出 ImageReceiver 返回的 JPEG 数据
   */
  private async flushFrameBuffers(): Promise<void> {
    const t0 = Date.now();
    let totalBytes = 0;

    for (let i = 0; i < this.frameBuffers.length; i++) {
      const frameData = this.frameList[i];
      const frameBuffer = this.frameBuffers[i];
      if (!frameData || !frameBuffer) continue;

      try {
        const tWrite0 = Date.now();
        const file = fs.openSync(frameData.path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);

        let frameBytes = 0;
        for (const buffer of frameBuffer.buffers) {
          fs.writeSync(file.fd, buffer);
          frameBytes += buffer.byteLength;
        }
        fs.closeSync(file);

        totalBytes += frameBytes;
        console.info(`[Flush] Frame ${i}: format=${frameBuffer.format}, bytes=${frameBytes}, write=${Date.now() - tWrite0}ms`);
      } catch (err) {
        let error = err as BusinessError;
        console.error(`[Flush] Frame ${i} failed: code=${error.code}, message=${error.message}`);
      }
    }
    this.frameBuffers = [];
    console.info(`[Flush] ${this.frameList.length} frames saved, ${totalBytes} bytes total, cost=${Date.now() - t0}ms`);
  }

  /**
   * 分析截图帧率
   */
  async analyzeFrameRate(): Promise<AnalysisResult> {
    const totalFrames = this.frameList.length;
    const expectedIntervalMs = this.options.intervalMs;
    const expectedFps = Math.round(1000 / expectedIntervalMs);

    let totalCaptureTime = 0;
    let maxCaptureTime = 0;
    let abnormalCount = 0;
    let abnormalTimestamps: number[] = [];

    for (let i = 0; i < this.captureTimes.length; i++) {
      const captureTime = this.captureTimes[i];
      totalCaptureTime += captureTime;
      if (captureTime > maxCaptureTime) maxCaptureTime = captureTime;

      if (captureTime > expectedIntervalMs * 0.8) {
        abnormalCount++;
        if (this.frameList[i]) {
          abnormalTimestamps.push(this.frameList[i].timestamp);
        }
      }
    }

    const avgCaptureTime = totalCaptureTime / (this.captureTimes.length || 1);
    const actualFps = totalFrames / this.options.durationSec;
    const frameDropRate = Math.abs(actualFps - expectedFps) / expectedFps;

    let status: 'NORMAL' | 'WARNING' | 'ABNORMAL' = 'NORMAL';
    let message = '';

    if (frameDropRate > 0.2 || abnormalCount > totalFrames * 0.1) {
      status = 'ABNORMAL';
      message = `Significant frame drop detected: expected ${expectedFps}fps, actual ${actualFps.toFixed(1)}fps`;
    } else if (frameDropRate > 0.05 || abnormalCount > totalFrames * 0.03) {
      status = 'WARNING';
      message = `Mild frame fluctuation detected: ${(frameDropRate * 100).toFixed(1)}% drop rate`;
    } else {
      message = 'Frame rate normal, no significant impact detected';
    }

    return {
      totalFrames: totalFrames,
      expectedFps: expectedFps,
      actualFps: actualFps,
      frameDropRate: frameDropRate,
      avgCaptureTimeMs: avgCaptureTime,
      maxCaptureTimeMs: maxCaptureTime,
      abnormalTimestamps: abnormalTimestamps,
      status: status,
      message: message
    };
  }

  getFrameData(): FrameData[] {
    return this.frameList;
  }

  async cleanup(): Promise<void> {
    await this.stopContinuousCapture();
    await this.destroyVirtualScreen();
  }
}
