#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _123
{
    uint4 _m0;
    uint4 _m1;
    uint4 _m2;
    uint4 _m3;
    uint4 _m4;
    uint4 _m5;
};

constant uint3 gl_WorkGroupSize [[maybe_unused]] = uint3(8u, 8u, 1u);

kernel void main0(constant _123& _125 [[buffer(0)]], texture2d<float> _154 [[texture(0)]], texture2d<float, access::write> _732 [[texture(1)]], sampler _154Smplr [[sampler(0)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]])
{
    do
    {
        bool _686 = gl_GlobalInvocationID.x >= (_125._m4.z * 2u);
        bool _696;
        if (!_686)
        {
            _696 = gl_GlobalInvocationID.y >= _125._m4.w;
        }
        else
        {
            _696 = _686;
        }
        if (_696)
        {
            break;
        }
        uint _711 = (gl_GlobalInvocationID.x / _125._m4.z) * _125._m4.z;
        int2 _884 = int2(uint2(gl_GlobalInvocationID.x - _711, gl_GlobalInvocationID.y));
        int2 _1254 = int2(_125._m4.zw) - int2(1);
        int2 _1255 = clamp(_884 + int2(0, -1), int2(0), _1254);
        int _1260 = int(_711);
        _1255.x = _1255.x + _1260;
        float4 _1268 = _154.read(uint2(_1255), 0);
        int2 _1278 = clamp(_884 + int2(-1, 0), int2(0), _1254);
        _1278.x = _1278.x + _1260;
        float4 _1291 = _154.read(uint2(_1278), 0);
        int2 _1301 = clamp(_884, int2(0), _1254);
        _1301.x = _1301.x + _1260;
        float4 _1314 = _154.read(uint2(_1301), 0);
        int2 _1324 = clamp(_884 + int2(1, 0), int2(0), _1254);
        _1324.x = _1324.x + _1260;
        float4 _1337 = _154.read(uint2(_1324), 0);
        int2 _1347 = clamp(_884 + int2(0, 1), int2(0), _1254);
        _1347.x = _1347.x + _1260;
        float4 _1360 = _154.read(uint2(_1347), 0);
        float _905 = _1268.x;
        float _907 = _1268.y;
        float _909 = _1268.z;
        float _911 = _1291.x;
        float _913 = _1291.y;
        float _915 = _1291.z;
        float _917 = _1314.x;
        float _919 = _1314.y;
        float _921 = _1314.z;
        float _923 = _1337.x;
        float _925 = _1337.y;
        float _927 = _1337.z;
        float _929 = _1360.x;
        float _931 = _1360.y;
        float _933 = _1360.z;
        float _1061 = fast::min(fast::min(_905, fast::min(_911, _923)), _929);
        float _1067 = fast::min(fast::min(_907, fast::min(_913, _925)), _931);
        float _1073 = fast::min(fast::min(_909, fast::min(_915, _927)), _933);
        float _1079 = fast::max(fast::max(_905, fast::max(_911, _923)), _929);
        float _1085 = fast::max(fast::max(_907, fast::max(_913, _925)), _931);
        float _1091 = fast::max(fast::max(_909, fast::max(_915, _927)), _933);
        float _1181 = fast::max(-0.1875, fast::min(fast::max(fast::max(-(fast::min(_1061, _917) * (0.25 / _1079)), (1.0 - fast::max(_1079, _917)) * (1.0 / ((4.0 * _1061) + (-4.0)))), fast::max(fast::max(-(fast::min(_1067, _919) * (0.25 / _1085)), (1.0 - fast::max(_1085, _919)) * (1.0 / ((4.0 * _1067) + (-4.0)))), fast::max(-(fast::min(_1073, _921) * (0.25 / _1091)), (1.0 - fast::max(_1091, _921)) * (1.0 / ((4.0 * _1073) + (-4.0)))))), 0.0)) * as_type<float>(_125._m0.x);
        float _1186 = (4.0 * _1181) + 1.0;
        float _1622 = as_type<float>(2129764351u - as_type<uint>(_1186));
        float _1630 = _1622 * (((-_1622) * _1186) + 2.0);
        _732.write(float4(((_1181 * (((_905 + _911) + _929) + _923)) + _917) * _1630, ((_1181 * (((_907 + _913) + _931) + _925)) + _919) * _1630, ((_1181 * (((_909 + _915) + _933) + _927)) + _921) * _1630, 1.0), uint2(int2(gl_GlobalInvocationID.xy)));
        break;
    } while(false);
}
