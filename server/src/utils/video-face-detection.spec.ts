import {
  getVideoFaceFrameConfigHash,
  selectVideoFaceFrameTimestamps,
  VideoFaceDetectionConfig,
} from 'src/utils/video-face-detection';
import { describe, expect, it } from 'vitest';

const config: VideoFaceDetectionConfig = {
  enabled: true,
  intervalSeconds: 5,
  maxFramesPerVideo: 30,
  downscaleLongEdge: 1440,
};

describe('selectVideoFaceFrameTimestamps', () => {
  it('samples one frame in the middle when the video is shorter than the interval', () => {
    expect(selectVideoFaceFrameTimestamps(3, config)).toEqual([1.5]);
  });

  it('samples centered buckets for longer videos', () => {
    expect(selectVideoFaceFrameTimestamps(30, config)).toEqual([2.5, 7.5, 12.5, 17.5, 22.5, 27.5]);
  });

  it('respects maxFramesPerVideo as a hard cap and distributes samples across the full video', () => {
    expect(selectVideoFaceFrameTimestamps(300, { ...config, maxFramesPerVideo: 3 })).toEqual([50, 150, 250]);
  });

  it('samples the center of the trailing bucket instead of the end of the video', () => {
    expect(selectVideoFaceFrameTimestamps(12, config)).toEqual([2.5, 7.5, 11]);
  });

  it('returns no timestamps for invalid durations', () => {
    expect(selectVideoFaceFrameTimestamps(0, config)).toEqual([]);
    expect(selectVideoFaceFrameTimestamps(Number.NaN, config)).toEqual([]);
  });
});

describe('getVideoFaceFrameConfigHash', () => {
  it('changes when sampling-affecting config changes', () => {
    expect(getVideoFaceFrameConfigHash(config)).not.toEqual(
      getVideoFaceFrameConfigHash({ ...config, downscaleLongEdge: 1024 }),
    );
  });
});
