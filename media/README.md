# media/

表盘动画素材，Xcode 工程会把这里的文件原样打包进手表 App。

| 文件 | 内容 |
|---|---|
| `p3r-0000.png` … `p3r-0079.png` | 80 帧动画，416×600 像素（2 倍密度，208×300 点），12 fps、约 6.67 秒一循环 |
| `poster-retina.png` | 第一帧，用作显示动画前的预热静帧 |
| `frames.json` | 帧数、时长、帧率等参数，App 运行时读取 |

这些帧取自《女神异闻录 3 Reload》官网开场视频，版权归 ATLUS / SEGA，**仅供课程作业使用，不在 MIT 许可范围内，请勿再分发**（见 [LICENSE](../LICENSE)）。

想换成自己的视频，用 `scripts/prepare_frames.swift` 重新生成即可覆盖，见 [教程](../docs/教程.md#3-可选换成你自己的视频)。
