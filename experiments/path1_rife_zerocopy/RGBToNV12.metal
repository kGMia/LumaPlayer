#include <metal_stdlib>
using namespace metal;

// 零拷贝从 FP16 RGB 张量直接转换回 VideoToolbox / mpv IOSurface NV12 纹理
// 对应 BT.709 limited range 转换矩阵
kernel void rgb_tensor_to_nv12(
    const device half* rgb_in [[buffer(0)]],
    texture2d<float, access::write> y_tex [[texture(0)]],
    texture2d<float, access::write> uv_tex [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = y_tex.get_width();
    uint height = y_tex.get_height();
    if (gid.x >= width || gid.y >= height) return;

    uint plane_size = width * height;
    uint pixel_idx = gid.y * width + gid.x;

    float r = float(rgb_in[0 * plane_size + pixel_idx]);
    float g = float(rgb_in[1 * plane_size + pixel_idx]);
    float b = float(rgb_in[2 * plane_size + pixel_idx]);

    // BT.709 变换:
    // Y  = 16/255 + (219/255) * (0.2126*R + 0.7152*G + 0.0722*B)
    // Cb = 128/255 + (224/255) * (-0.114572*R - 0.385428*G + 0.5*B)
    // Cr = 128/255 + (224/255) * (0.5*R - 0.454153*G - 0.045847*B)
    float y_val = (16.0 / 255.0) + (219.0 / 255.0) * (0.2126 * r + 0.7152 * g + 0.0722 * b);
    y_tex.write(float4(clamp(y_val, 0.0, 1.0), 0.0, 0.0, 1.0), gid);

    // NV12 的 UV 平面为 4:2:0 下采样 (仅在偶数像素位置计算并写入一次)
    if ((gid.x % 2 == 0) && (gid.y % 2 == 0)) {
        // 读取 2x2 邻域做简易下采样以消除锯齿
        float u_val = 0.0;
        float v_val = 0.0;
        for (uint dy = 0; dy < 2 && (gid.y + dy < height); dy++) {
            for (uint dx = 0; dx < 2 && (gid.x + dx < width); dx++) {
                uint sub_idx = (gid.y + dy) * width + (gid.x + dx);
                float sub_r = float(rgb_in[0 * plane_size + sub_idx]);
                float sub_g = float(rgb_in[1 * plane_size + sub_idx]);
                float sub_b = float(rgb_in[2 * plane_size + sub_idx]);
                u_val += (-0.114572 * sub_r - 0.385428 * sub_g + 0.500000 * sub_b);
                v_val += ( 0.500000 * sub_r - 0.454153 * sub_g - 0.045847 * sub_b);
            }
        }
        u_val = (u_val * 0.25) * (224.0 / 255.0) + (128.0 / 255.0);
        v_val = (v_val * 0.25) * (224.0 / 255.0) + (128.0 / 255.0);

        uint2 uv_gid = gid / 2;
        uv_tex.write(float4(clamp(u_val, 0.0, 1.0), clamp(v_val, 0.0, 1.0), 0.0, 1.0), uv_gid);
    }
}
