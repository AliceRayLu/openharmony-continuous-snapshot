// VirtualScreenManager.ets
import screen from '@ohos.screen';
import display from '@ohos.display';
import image from '@ohos.multimedia.image';
import fs from '@ohos.file.fs';
import { BusinessError } from '@ohos.base';

export interface ScreenshotOptions {
  intervalMs: number;      // 截图间隔（毫秒）
  durationSec: number;     // 总持续时间（秒）
  outputDir: string;       // 输出目录
  pixelThreshold?: number; // 帧差异阈值（默认0.95）
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
  private virtualScreenId: number = -1;
  private mirrorGroupId: number = -1;
  private mainScreenId: number = -1;
  private defaultDisplayId: number = -1;
  private isCapturing: boolean = false;
  private timerId: number = -1;
  private frameList: FrameData[] = [];
  private options: ScreenshotOptions;
  private captureStartTime: number = 0;
  private captureTimes: number[] = [];
  private imageReceiver: image.ImageReceiver | null = null;
  private frameBuffers: ArrayBuffer[] = [];

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
    this.isCapturing = true;

    // 创建 ImageReceiver 并绑定虚拟屏 surface，仅在截图期间开启
    const defaultDisplay = display.getDefaultDisplaySync();
    this.imageReceiver = image.createImageReceiver(
      { width: defaultDisplay.width, height: defaultDisplay.height },
      image.ImageFormat.JPEG,
      3
    );
    console.info(`[Capture] ImageReceiver created, size=${defaultDisplay.width}x${defaultDisplay.height}`);

    const surfaceId = await this.imageReceiver.getReceivingSurfaceId();
    console.info(`[Capture] ImageReceiver surfaceId: ${surfaceId}`);

    await screen.setVirtualScreenSurface(this.virtualScreenId, surfaceId);
    console.info(`[Capture] Surface bound to virtual screen`);

    // 在此之后才开始计时，不把 setup 耗时算入帧率
    this.captureStartTime = Date.now();

    const totalFrames = Math.ceil((this.options.durationSec * 1000) / this.options.intervalMs);
    let frameIndex = 0;

    console.info(`[Capture] Starting continuous capture, target ${totalFrames} frames, intervalMs=${this.options.intervalMs}, durationSec=${this.options.durationSec}, outputDir=${this.options.outputDir}, virtualScreenId=${this.virtualScreenId}, mainScreenId=${this.mainScreenId}, defaultDisplayId=${this.defaultDisplayId}`);

    return new Promise((resolve, reject) => {
      this.timerId = setInterval(async () => {
        if (!this.isCapturing) {
          clearInterval(this.timerId);
          await this.flushFrameBuffers();
          resolve(this.frameList);
          return;
        }

        const frameStart = Date.now();
        try {
          const frameData = await this.captureSingleFrame(frameIndex);
          frameData.index = frameIndex;
          this.frameList.push(frameData);
          this.captureTimes.push(Date.now() - frameStart);

          if (onProgress) {
            onProgress((frameIndex + 1) / totalFrames);
          }

          frameIndex++;

          const elapsed = (Date.now() - this.captureStartTime) / 1000;
          if (elapsed >= this.options.durationSec) {
            await this.stopContinuousCapture();
            resolve(this.frameList);
          }
        } catch (err) {
          let error = err as BusinessError;
          console.error(`[Capture] Frame ${frameIndex} failed: code=${error.code}, message=${error.message}`);
        }
      }, this.options.intervalMs);
    });
  }

  /**
   * 停止连续截图
   */
  async stopContinuousCapture(): Promise<void> {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.isCapturing = false;
    await this.flushFrameBuffers();
    if (this.imageReceiver) {
      await this.imageReceiver.release();
      this.imageReceiver = null;
      console.info('[Capture] ImageReceiver released');
    }
    console.info(`[Capture] Stopped, captured ${this.frameList.length} frames`);
  }

  /**
   * 单帧截图 - 使用 ImageReceiver + setVirtualScreenSurface
   * 帧数据先缓存到内存，截图结束后统一写盘
   */
  private async captureSingleFrame(frameIndex: number): Promise<FrameData> {
    const t0 = Date.now();
    const timestamp = Date.now() * 1000000;
    const outputPath = `${this.options.outputDir}/frame_${timestamp}.jpg`;

    try {
      const defaultDisplay = display.getDefaultDisplaySync();

      const img = await this.imageReceiver!.readLatestImage();
      const t1 = Date.now();

      const component = await img.getComponent(image.ComponentType.JPEG);
      const t2 = Date.now();

      // 拷贝一份独立的原始帧数据，避免 ImageReceiver 复用底层缓冲导致所有帧变成同一张
      const frameCopy = component.byteBuffer.slice(0);
      this.frameBuffers.push(frameCopy);
      const t3 = Date.now();

      img.release();
      const t4 = Date.now();

      const elapsed = t4 - t0;
      console.info(`[Capture] Frame ${frameIndex}: img.format=${img.format}, img.size=${img.size.width}x${img.size.height}, rawSize=${component.byteBuffer.byteLength}, rowStride=${component.rowStride}, pixelStride=${component.pixelStride}, readLatest=${t1 - t0}ms, getComponent=${t2 - t1}ms, copy=${t3 - t2}ms, release=${t4 - t3}ms, total=${elapsed}ms`);

      return {
        index: frameIndex,
        timestamp: timestamp,
        path: outputPath,
        hash: `${Date.now()}_${Math.random()}`,
        width: defaultDisplay.width,
        height: defaultDisplay.height
      };
    } catch (err) {
      let error = err as BusinessError;
      console.error(`[Capture] Frame ${frameIndex} capture failed, code=${error.code}, message=${error.message}`);
      throw new Error(`Capture failed: ${error.message}`);
    }
  }

  /**
   * 批量编码并写入磁盘：原始 RGBA buffer → createPixelMap(RGBA) → packToData(JPEG) → 写盘
   */
  private async flushFrameBuffers(): Promise<void> {
    const t0 = Date.now();
    let totalBytes = 0;
    const width = this.frameList[0]?.width ?? 720;
    const height = this.frameList[0]?.height ?? 1280;

    for (let i = 0; i < this.frameBuffers.length; i++) {
      const frameData = this.frameList[i];
      if (!frameData) continue;

      try {
        const tEncode0 = Date.now();

        const pixelMap = await image.createPixelMap(this.frameBuffers[i], {
          size: { width: width, height: height },
          srcPixelFormat: image.PixelMapFormat.RGBA_8888,
          pixelFormat: image.PixelMapFormat.RGBA_8888
        });
        const tPM = Date.now();

        const packer = image.createImagePacker();
        const jpegBuffer = await packer.packToData(pixelMap, {
          format: 'image/jpeg',
          quality: 60
        });
        await packer.release();
        pixelMap.release();
        const tJPEG = Date.now();

        const file = fs.openSync(frameData.path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
        fs.writeSync(file.fd, jpegBuffer);
        fs.closeSync(file);
        totalBytes += jpegBuffer.byteLength;

        console.info(`[Flush] Frame ${i}: createPM=${tPM - tEncode0}ms, encode=${tJPEG - tPM}ms, jpegSize=${jpegBuffer.byteLength}`);
      } catch (err) {
        let error = err as BusinessError;
        console.error(`[Flush] Frame ${i} failed: code=${error.code}, message=${error.message}`);
      }
    }
    this.frameBuffers = [];
    console.info(`[Flush] ${this.frameList.length} frames encoded, ${totalBytes} bytes total, cost=${Date.now() - t0}ms`);
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
