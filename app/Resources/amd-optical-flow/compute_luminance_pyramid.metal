// This file is part of the FidelityFX SDK.
//
// Copyright (C) 2024 Advanced Micro Devices, Inc.
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files(the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and /or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions :
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
// Generated from AMD SDKv1.1.4; see SOURCE.md.
#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    
    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

template<typename T>
inline T spvQuadSwap(T value, uint dir)
{
    return quad_shuffle_xor(value, dir + 1);
}

template<>
inline bool spvQuadSwap(bool value, uint dir)
{
    return !!quad_shuffle_xor((ushort)value, dir + 1);
}

template<uint N>
inline vec<bool, N> spvQuadSwap(vec<bool, N> value, uint dir)
{
    return (vec<bool, N>)quad_shuffle_xor((vec<ushort, N>)value, dir + 1);
}

kernel void CS(texture2d<uint> _281 [[texture(0)]], texture2d<uint, access::write, memory_coherence_device> _300 [[texture(1)]], texture2d<uint, access::write, memory_coherence_device> _308 [[texture(2)]], texture2d<uint, access::write, memory_coherence_device> _316 [[texture(3)]], texture2d<uint, access::write, memory_coherence_device> _324 [[texture(4)]], texture2d<uint, access::write, memory_coherence_device> _332 [[texture(5)]], texture2d<uint, access::write, memory_coherence_device> _340 [[texture(6)]], uint3 gl_WorkGroupID [[threadgroup_position_in_grid]], uint gl_LocalInvocationIndex [[thread_index_in_threadgroup]])
{
    threadgroup spvUnsafeArray<spvUnsafeArray<float, 16>, 16> _377;
    threadgroup spvUnsafeArray<spvUnsafeArray<float, 16>, 16> _383;
    threadgroup spvUnsafeArray<spvUnsafeArray<float, 16>, 16> _388;
    threadgroup spvUnsafeArray<spvUnsafeArray<float, 16>, 16> _393;
    int2 _1482 = int2(int3(gl_WorkGroupID).xy);
    uint2 _1528 = uint2(_1482);
    uint _1530 = uint(int(gl_LocalInvocationIndex));
    uint _1573 = _1530 % 64u;
    uint _1581 = ((_1573 & 1u) | ((_1573 >> 2u) & 6u)) + (8u * ((_1530 >> uint(6)) % 2u));
    uint _1587 = (((_1573 >> 1u) & 3u) | ((_1573 >> 3u) & 4u)) + (8u * (_1530 >> uint(7)));
    int2 _1793 = int2(_1528 * uint2(64u));
    uint _1795 = _1581 * 2u;
    int _1796 = int(_1795);
    uint _1798 = _1587 * 2u;
    int _1799 = int(_1798);
    int2 _1801 = _1793 + int2(_1796, _1799);
    int2 _1805 = int2(_1528 * uint2(32u));
    int _1807 = int(_1581);
    int _1809 = int(_1587);
    uint2 _1813 = uint2(_1801);
    float4 _2185 = (((float4(float(_281.read(uint2(int2(float2(_1801)))).x), 0.0, 0.0, 0.0) + float4(float(_281.read(uint2(int2(float2(int2(_1813 + uint2(0u, 1u)))))).x), 0.0, 0.0, 0.0)) + float4(float(_281.read(uint2(int2(float2(int2(_1813 + uint2(1u, 0u)))))).x), 0.0, 0.0, 0.0)) + float4(float(_281.read(uint2(int2(float2(int2(_1813 + uint2(1u)))))).x), 0.0, 0.0, 0.0)) * 0.25;
    _300.write(uint4(uint(_2185.x)), uint2((_1805 + int2(_1807, _1809))));
    int _1829 = int(_1795 + 32u);
    int2 _1834 = _1793 + int2(_1829, _1799);
    int _1841 = int(_1581 + 16u);
    uint2 _1847 = uint2(_1834);
    float4 _2374 = (((float4(float(_281.read(uint2(int2(float2(_1834)))).x), 0.0, 0.0, 0.0) + float4(float(_281.read(uint2(int2(float2(int2(_1847 + uint2(0u, 1u)))))).x), 0.0, 0.0, 0.0)) + float4(float(_281.read(uint2(int2(float2(int2(_1847 + uint2(1u, 0u)))))).x), 0.0, 0.0, 0.0)) + float4(float(_281.read(uint2(int2(float2(int2(_1847 + uint2(1u)))))).x), 0.0, 0.0, 0.0)) * 0.25;
    _300.write(uint4(uint(_2374.x)), uint2((_1805 + int2(_1841, _1809))));
    int _1866 = int(_1798 + 32u);
    int2 _1868 = _1793 + int2(_1796, _1866);
    int _1877 = int(_1587 + 16u);
    uint2 _1881 = uint2(_1868);
    float4 _2563 = (((float4(float(_281.read(uint2(int2(float2(_1868)))).x), 0.0, 0.0, 0.0) + float4(float(_281.read(uint2(int2(float2(int2(_1881 + uint2(0u, 1u)))))).x), 0.0, 0.0, 0.0)) + float4(float(_281.read(uint2(int2(float2(int2(_1881 + uint2(1u, 0u)))))).x), 0.0, 0.0, 0.0)) + float4(float(_281.read(uint2(int2(float2(int2(_1881 + uint2(1u)))))).x), 0.0, 0.0, 0.0)) * 0.25;
    _300.write(uint4(uint(_2563.x)), uint2((_1805 + int2(_1807, _1877))));
    int2 _1903 = _1793 + int2(_1829, _1866);
    uint2 _1917 = uint2(_1903);
    float4 _2752 = (((float4(float(_281.read(uint2(int2(float2(_1903)))).x), 0.0, 0.0, 0.0) + float4(float(_281.read(uint2(int2(float2(int2(_1917 + uint2(0u, 1u)))))).x), 0.0, 0.0, 0.0)) + float4(float(_281.read(uint2(int2(float2(int2(_1917 + uint2(1u, 0u)))))).x), 0.0, 0.0, 0.0)) + float4(float(_281.read(uint2(int2(float2(int2(_1917 + uint2(1u)))))).x), 0.0, 0.0, 0.0)) * 0.25;
    _300.write(uint4(uint(_2752.x)), uint2((_1805 + int2(_1841, _1877))));
    float4 _2820 = spvQuadSwap(_2185, 0u);
    float4 _2822 = spvQuadSwap(_2185, 1u);
    float4 _2824 = spvQuadSwap(_2185, 2u);
    float4 _2839 = (((_2185 + _2820) + _2822) + _2824) * 0.25;
    float4 _2852 = spvQuadSwap(_2374, 0u);
    float4 _2854 = spvQuadSwap(_2374, 1u);
    float4 _2856 = spvQuadSwap(_2374, 2u);
    float4 _2871 = (((_2374 + _2852) + _2854) + _2856) * 0.25;
    float4 _2884 = spvQuadSwap(_2563, 0u);
    float4 _2886 = spvQuadSwap(_2563, 1u);
    float4 _2888 = spvQuadSwap(_2563, 2u);
    float4 _2903 = (((_2563 + _2884) + _2886) + _2888) * 0.25;
    float4 _2916 = spvQuadSwap(_2752, 0u);
    float4 _2918 = spvQuadSwap(_2752, 1u);
    float4 _2920 = spvQuadSwap(_2752, 2u);
    float4 _2935 = (((_2752 + _2916) + _2918) + _2920) * 0.25;
    bool _1948 = (_1530 % 4u) == 0u;
    if (_1948)
    {
        int2 _1953 = int2(_1528 * uint2(16u));
        uint _1955 = _1581 / 2u;
        int _1956 = int(_1955);
        uint _1958 = _1587 / 2u;
        int _1959 = int(_1958);
        float _2944 = _2839.x;
        _308.write(uint4(uint(_2944)), uint2((_1953 + int2(_1956, _1959))));
        _377[_1955][_1958] = _2944;
        _383[_1955][_1958] = _2839.y;
        _388[_1955][_1958] = _2839.z;
        _393[_1955][_1958] = _2839.w;
        uint _1979 = _1955 + 8u;
        int _1980 = int(_1979);
        float _3020 = _2871.x;
        _308.write(uint4(uint(_3020)), uint2((_1953 + int2(_1980, _1959))));
        _377[_1979][_1958] = _3020;
        _383[_1979][_1958] = _2871.y;
        _388[_1979][_1958] = _2871.z;
        _393[_1979][_1958] = _2871.w;
        uint _2007 = _1958 + 8u;
        int _2008 = int(_2007);
        float _3096 = _2903.x;
        _308.write(uint4(uint(_3096)), uint2((_1953 + int2(_1956, _2008))));
        _377[_1955][_2007] = _3096;
        _383[_1955][_2007] = _2903.y;
        _388[_1955][_2007] = _2903.z;
        _393[_1955][_2007] = _2903.w;
        float _3172 = _2935.x;
        _308.write(uint4(uint(_3172)), uint2((_1953 + int2(_1980, _2008))));
        _377[_1979][_2007] = _3172;
        _383[_1979][_2007] = _2935.y;
        _388[_1979][_2007] = _2935.z;
        _393[_1979][_2007] = _2935.w;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float _3374 = _377[_1581][_1587];
    float _3378 = _383[_1581][_1587];
    float _3382 = _388[_1581][_1587];
    float4 _3387 = float4(_3374, _3378, _3382, _393[_1581][_1587]);
    float4 _3400 = spvQuadSwap(_3387, 0u);
    float4 _3402 = spvQuadSwap(_3387, 1u);
    float4 _3404 = spvQuadSwap(_3387, 2u);
    float4 _3419 = (((_3387 + _3400) + _3402) + _3404) * 0.25;
    if (_1948)
    {
        uint _3352 = _1587 / 2u;
        float _3428 = _3419.x;
        _316.write(uint4(uint(_3428)), uint2((int2(_1528 * uint2(8u)) + int2(int(_1581 / 2u), int(_3352)))));
        uint _3364 = _1581 + (_3352 % 2u);
        _377[_3364][_1587] = _3428;
        _383[_3364][_1587] = _3419.y;
        _388[_3364][_1587] = _3419.z;
        _393[_3364][_1587] = _3419.w;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (_1530 < 64u)
    {
        uint _3516 = _1795 + (_1587 % 2u);
        float _3558 = _377[_3516][_1798];
        float _3562 = _383[_3516][_1798];
        float _3566 = _388[_3516][_1798];
        float4 _3571 = float4(_3558, _3562, _3566, _393[_3516][_1798]);
        float4 _3584 = spvQuadSwap(_3571, 0u);
        float4 _3586 = spvQuadSwap(_3571, 1u);
        float4 _3588 = spvQuadSwap(_3571, 2u);
        float4 _3603 = (((_3571 + _3584) + _3586) + _3588) * 0.25;
        if (_1948)
        {
            uint _3534 = _1587 / 2u;
            float _3612 = _3603.x;
            _324.write(uint4(uint(_3612)), uint2((int2(_1528 * uint2(4u)) + int2(int(_1581 / 2u), int(_3534)))));
            uint _3546 = _1795 + _3534;
            _377[_3546][_1798] = _3612;
            _383[_3546][_1798] = _3603.y;
            _388[_3546][_1798] = _3603.z;
            _393[_3546][_1798] = _3603.w;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (_1530 < 16u)
    {
        uint _3699 = (_1581 * 4u) + _1587;
        uint _3701 = _1587 * 4u;
        float _3738 = _377[_3699][_3701];
        float _3742 = _383[_3699][_3701];
        float _3746 = _388[_3699][_3701];
        float4 _3751 = float4(_3738, _3742, _3746, _393[_3699][_3701]);
        float4 _3764 = spvQuadSwap(_3751, 0u);
        float4 _3766 = spvQuadSwap(_3751, 1u);
        float4 _3768 = spvQuadSwap(_3751, 2u);
        float4 _3783 = (((_3751 + _3764) + _3766) + _3768) * 0.25;
        if (_1948)
        {
            uint _3714 = _1581 / 2u;
            float _3792 = _3783.x;
            _332.write(uint4(uint(_3792)), uint2((int2(_1528 * uint2(2u)) + int2(int(_3714), int(_1587 / 2u)))));
            uint _3728 = _3714 + _1587;
            _377[_3728][0u] = _3792;
            _383[_3728][0u] = _3783.y;
            _388[_3728][0u] = _3783.z;
            _393[_3728][0u] = _3783.w;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (_1530 < 4u)
    {
        float4 _3907 = float4(_377[_1530][0u], _383[_1530][0u], _388[_1530][0u], _393[_1530][0u]);
        float4 _3920 = spvQuadSwap(_3907, 0u);
        float4 _3922 = spvQuadSwap(_3907, 1u);
        float4 _3924 = spvQuadSwap(_3907, 2u);
        if (_1948)
        {
            _340.write(uint4(uint(((((_3907 + _3920) + _3922) + _3924) * 0.25).x)), uint2(_1482));
        }
    }
}

