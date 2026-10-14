#include <metal_stdlib>
using namespace metal;

// 零拷贝直接从 VideoToolbox IOSurface NV12 转换到 FP16 RGB 张量
kernel void nv12_to_rgb_tensor(
    texture2d<float, access::read> y_tex [[texture(0)]],
    texture2d<float, access::read> uv_tex [[texture(1)]],
    device half* rgb_out [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = y_tex.get_width();
    uint height = y_tex.get_height();
    if (gid.x >= width || gid.y >= height) return;

    float y = y_tex.read(gid).r;
    float2 uv = uv_tex.read(gid / 2).rg - float2(0.5, 0.5);

    // BT.709 限幅转换为标准线性 RGB
    y = (y - (16.0 / 255.0)) * (255.0 / 219.0);
    float r = clamp(y + 1.5748 * uv.y, 0.0, 1.0);
    float g = clamp(y - 0.1873 * uv.x - 0.4681 * uv.y, 0.0, 1.0);
    float b = clamp(y + 1.8556 * uv.x, 0.0, 1.0);

    // 写入 MPSGraph 张量 [1, 3, H, W] 布局
    uint plane_size = width * height;
    uint pixel_idx = gid.y * width + gid.x;
    rgb_out[0 * plane_size + pixel_idx] = half(r);
    rgb_out[1 * plane_size + pixel_idx] = half(g);
    rgb_out[2 * plane_size + pixel_idx] = half(b);
}
