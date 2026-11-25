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

// Implementation of signed integer mod accurate to SPIR-V specification
template<typename Tx, typename Ty>
inline Tx spvSMod(Tx x, Ty y)
{
    Tx remainder = x - y * (x / y);
    return select(Tx(remainder + y), remainder, remainder == 0 || (x >= 0) == (y >= 0));
}

template <typename ImageT>
void spvImageFence(ImageT img) { img.fence(); }

struct _402
{
    int2 _m0;
    uint _m1;
    uint _m2;
    uint _m3;
    uint _m4;
    float2 _m5;
};

constant int2 _3412 = {};

kernel void CS(constant _402& _404 [[buffer(0)]], texture2d<uint> _425 [[texture(0)]], texture2d<uint> _432 [[texture(1)]], texture2d<int, access::read_write> _441 [[texture(2)]], texture2d<uint> _456 [[texture(3)]], uint gl_SubgroupSize [[threads_per_simdgroup]], uint3 gl_WorkGroupID [[threadgroup_position_in_grid]], uint gl_LocalInvocationIndex [[thread_index_in_threadgroup]])
{
    threadgroup spvUnsafeArray<uint, 2> _640;
    threadgroup spvUnsafeArray<spvUnsafeArray<spvUnsafeArray<uint, 5>, 16>, 4> _662;
    threadgroup spvUnsafeArray<uint, 2> _713;
    threadgroup spvUnsafeArray<spvUnsafeArray<uint, 144>, 1> _766;
    threadgroup spvUnsafeArray<spvUnsafeArray<uint, 2>, 8> _820;
    int2 _1239 = int2(int3(gl_WorkGroupID).xy);
    do
    {
        uint _1474 = uint(int(gl_LocalInvocationIndex));
        int _1476 = int(_1474 & 3u);
        int _1480 = int((_1474 >> 2u) & 15u);
        int _1490 = int(((_1474 >> 1u) & 1u) | (((_1474 >> 5u) & 1u) << 1u));
        int2 _1493 = _1239 << int2(uint2(4u));
        int2 _1496 = _1493 + (int2(_1476, _1480) * int2(4, 1));
        bool _3246;
        do
        {
            if (_404._m3 <= 5u)
            {
                _3246 = true;
                break;
            }
            else
            {
                _3246 = (_456.read(uint2(int2(1, 0))).x & 15u) != 0u;
                break;
            }
            break; // unreachable workaround
        } while(false);
        if (_3246)
        {
            if (((_1480 & 7) == 0) && ((_1476 & 1) == 0))
            {
                _441.write(int2(0).xyyy, uint2((_1496 >> int2(uint2(3u)))));
            }
            break;
        }
        uint _1348 = _404._m2 - 1u;
        int _1610 = _404._m0.x >> int(_404._m1);
        int _1616 = _1610 - 4;
        int _1618 = _1496.x;
        int _1622 = (_404._m0.y >> int(_404._m1)) - 1;
        int2 _1627 = int2(max(0, min(_1616, _1618)), max(0, min(_1622, _1496.y)));
        int2 _1632 = _1627 + int2(1, 0);
        int2 _1635 = _1627 + int2(2, 0);
        int2 _1638 = _1627 + int2(3, 0);
        uint _1722 = ((_425.read(uint2(_1627), 0).x | (_425.read(uint2(_1632), 0).x << uint(8))) | (_425.read(uint2(_1635), 0).x << uint(16))) | (_425.read(uint2(_1638), 0).x << uint(24));
        bool _1724 = _1618 < 0;
        uint _3251;
        if (_1724)
        {
            uint _1727 = _1722 & 255u;
            uint _3249;
            if (_1618 <= (-1))
            {
                _3249 = (_1722 << uint(8)) | _1727;
            }
            else
            {
                _3249 = _1722;
            }
            uint _3250;
            if (_1618 <= (-2))
            {
                _3250 = (_3249 << uint(8)) | _1727;
            }
            else
            {
                _3250 = _3249;
            }
            uint _3252;
            if (_1618 <= (-3))
            {
                _3252 = (_3250 << uint(8)) | _1727;
            }
            else
            {
                _3252 = _3250;
            }
            _3251 = _3252;
        }
        else
        {
            uint _3253;
            if (_1618 > _1616)
            {
                uint _1759 = _1722 & 4278190080u;
                uint _3247;
                if (_1618 >= (_1610 - 3))
                {
                    _3247 = (_1722 >> uint(8)) | _1759;
                }
                else
                {
                    _3247 = _1722;
                }
                uint _3248;
                if (_1618 >= (_1610 - 2))
                {
                    _3248 = (_3247 >> uint(8)) | _1759;
                }
                else
                {
                    _3248 = _3247;
                }
                uint _3254;
                if (_1618 >= (_1610 - 1))
                {
                    _3254 = (_3248 >> uint(8)) | _1759;
                }
                else
                {
                    _3254 = _3248;
                }
                _3253 = _3254;
            }
            else
            {
                _3253 = _1722;
            }
            _3251 = _3253;
        }
        uint _1935 = ((_432.read(uint2(_1627), 0).x | (_432.read(uint2(_1632), 0).x << uint(8))) | (_432.read(uint2(_1635), 0).x << uint(16))) | (_432.read(uint2(_1638), 0).x << uint(24));
        uint _3259;
        if (_1724)
        {
            uint _1940 = _1935 & 255u;
            uint _3257;
            if (_1618 <= (-1))
            {
                _3257 = (_1935 << uint(8)) | _1940;
            }
            else
            {
                _3257 = _1935;
            }
            uint _3258;
            if (_1618 <= (-2))
            {
                _3258 = (_3257 << uint(8)) | _1940;
            }
            else
            {
                _3258 = _3257;
            }
            uint _3260;
            if (_1618 <= (-3))
            {
                _3260 = (_3258 << uint(8)) | _1940;
            }
            else
            {
                _3260 = _3258;
            }
            _3259 = _3260;
        }
        else
        {
            uint _3261;
            if (_1618 > _1616)
            {
                uint _1972 = _1935 & 4278190080u;
                uint _3255;
                if (_1618 >= (_1610 - 3))
                {
                    _3255 = (_1935 >> uint(8)) | _1972;
                }
                else
                {
                    _3255 = _1935;
                }
                uint _3256;
                if (_1618 >= (_1610 - 2))
                {
                    _3256 = (_3255 >> uint(8)) | _1972;
                }
                else
                {
                    _3256 = _3255;
                }
                uint _3262;
                if (_1618 >= (_1610 - 1))
                {
                    _3262 = (_3256 >> uint(8)) | _1972;
                }
                else
                {
                    _3262 = _3256;
                }
                _3261 = _3262;
            }
            else
            {
                _3261 = _1935;
            }
            _3259 = _3261;
        }
        uint _2010 = _3251 & 255u;
        uint _2014 = _3259 & 255u;
        uint _2019 = _3251 >> uint(8);
        uint _2023 = _3259 >> uint(8);
        uint _2030 = _3251 >> uint(16);
        uint _2034 = _3259 >> uint(16);
        uint _2041 = _3251 >> uint(24);
        uint _2045 = _3259 >> uint(24);
        uint _2051 = uint(((abs(int(_2010) - int(_2014)) + abs(int(_2019 & 255u) - int(_2023 & 255u))) + abs(int(_2030 & 255u) - int(_2034 & 255u))) + abs(int(_2041 & 255u) - int(_2045 & 255u)));
        int2 _1359 = _1239 << int2(uint2(1u));
        int2 _3321;
        _3321.y = 0;
        int2 _3425;
        _3425 = _3321;
        int2 _3406;
        int2 _3426;
        for (; _3425.y < 2; _3406 = _3426, _3406.y = _3426.y + 1, _3425 = _3406)
        {
            int2 _3324 = _3425;
            _3324.x = 0;
            _3426 = _3324;
            int2 _3403;
            int _1374;
            for (;;)
            {
                _1374 = _3426.x;
                if (_1374 < 2)
                {
                    int2 _1379 = _1359 + _3426;
                    spvImageFence(_441);
                    int2 _3524 = select(int2(_441.read(uint2(_1379)).xy), int2(0), bool2(_404._m1 == _1348));
                    int _1387 = _3426.y;
                    int _1391 = (_1387 * 2) + _1374;
                    if (_1490 == _1391)
                    {
                        _820[_1480 & 7][_1476 & 1] = _3251;
                    }
                    int2 _1409 = (_1493 + (_3426 * int2(8))) + _3524;
                    int _2071 = _1409.x - 8;
                    int _2074 = _1409.y - 8;
                    for (int _3265 = int(gl_LocalInvocationIndex); _3265 < 144; _3265 += 64)
                    {
                        int _2088 = _2071 + (spvSMod(_3265, 6) * 4);
                        int2 _2149 = int2(max(0, min(_1616, _2088)), max(0, min(_1622, (_2074 + (_3265 / 6)))));
                        uint _2244 = ((_432.read(uint2(_2149), 0).x | (_432.read(uint2((_2149 + int2(1, 0))), 0).x << uint(8))) | (_432.read(uint2((_2149 + int2(2, 0))), 0).x << uint(16))) | (_432.read(uint2((_2149 + int2(3, 0))), 0).x << uint(24));
                        uint _3285;
                        if (_2088 < 0)
                        {
                            uint _2249 = _2244 & 255u;
                            uint _3283;
                            if (_2088 <= (-1))
                            {
                                _3283 = (_2244 << uint(8)) | _2249;
                            }
                            else
                            {
                                _3283 = _2244;
                            }
                            uint _3284;
                            if (_2088 <= (-2))
                            {
                                _3284 = (_3283 << uint(8)) | _2249;
                            }
                            else
                            {
                                _3284 = _3283;
                            }
                            uint _3286;
                            if (_2088 <= (-3))
                            {
                                _3286 = (_3284 << uint(8)) | _2249;
                            }
                            else
                            {
                                _3286 = _3284;
                            }
                            _3285 = _3286;
                        }
                        else
                        {
                            uint _3287;
                            if (_2088 > _1616)
                            {
                                uint _2281 = _2244 & 4278190080u;
                                uint _3281;
                                if (_2088 >= (_1610 - 3))
                                {
                                    _3281 = (_2244 >> uint(8)) | _2281;
                                }
                                else
                                {
                                    _3281 = _2244;
                                }
                                uint _3282;
                                if (_2088 >= (_1610 - 2))
                                {
                                    _3282 = (_3281 >> uint(8)) | _2281;
                                }
                                else
                                {
                                    _3282 = _3281;
                                }
                                uint _3288;
                                if (_2088 >= (_1610 - 1))
                                {
                                    _3288 = (_3282 >> uint(8)) | _2281;
                                }
                                else
                                {
                                    _3288 = _3282;
                                }
                                _3287 = _3288;
                            }
                            else
                            {
                                _3287 = _2244;
                            }
                            _3285 = _3287;
                        }
                        _766[0][_3265] = _3285;
                    }
                    threadgroup_barrier(mem_flags::mem_threadgroup);
                    uint4 _3267;
                    _3267 = uint4(0u);
                    for (int _3266 = 0; _3266 < 8; )
                    {
                        int _2344 = ((_1480 + _3266) * 6) + _1476;
                        int _2351 = _2344 + 1;
                        int _2358 = _2344 + 2;
                        int _2445 = int(_820[_3266][0] & 255u);
                        uint _2449 = _766[0][_2344] >> uint(8);
                        int _2455 = int((_820[_3266][0] >> uint(8)) & 255u);
                        int _2466 = int((_820[_3266][0] >> uint(16)) & 255u);
                        int _2477 = int((_820[_3266][0] >> uint(24)) & 255u);
                        uint _2404 = _766[0][_2351] & 255u;
                        uint _2406 = _2449 | (_2404 << uint(24));
                        uint _2408 = _766[0][_2351] >> uint(8);
                        uint _2495 = _2406 >> uint(8);
                        uint _2416 = _2408 & 255u;
                        uint _2418 = _2495 | (_2416 << uint(24));
                        uint _2541 = _2418 >> uint(8);
                        uint _2430 = _2541 | (((_2408 >> uint(8)) & 255u) << uint(24));
                        uint4 _2368 = _3267 + uint4(uint(((abs(int(_766[0][_2344] & 255u) - _2445) + abs(int(_2449 & 255u) - _2455)) + abs(int((_766[0][_2344] >> uint(16)) & 255u) - _2466)) + abs(int((_766[0][_2344] >> uint(24)) & 255u) - _2477)), uint(((abs(int(_2406 & 255u) - _2445) + abs(int(_2495 & 255u) - _2455)) + abs(int((_2406 >> uint(16)) & 255u) - _2466)) + abs(int((_2406 >> uint(24)) & 255u) - _2477)), uint(((abs(int(_2418 & 255u) - _2445) + abs(int(_2541 & 255u) - _2455)) + abs(int((_2418 >> uint(16)) & 255u) - _2466)) + abs(int((_2418 >> uint(24)) & 255u) - _2477)), uint(((abs(int(_2430 & 255u) - _2445) + abs(int((_2430 >> uint(8)) & 255u) - _2455)) + abs(int((_2430 >> uint(16)) & 255u) - _2466)) + abs(int((_2430 >> uint(24)) & 255u) - _2477)));
                        int _2679 = int(_820[_3266][1] & 255u);
                        int _2689 = int((_820[_3266][1] >> uint(8)) & 255u);
                        int _2700 = int((_820[_3266][1] >> uint(16)) & 255u);
                        int _2711 = int((_820[_3266][1] >> uint(24)) & 255u);
                        uint _2640 = _2408 | ((_766[0][_2358] & 255u) << uint(24));
                        uint _2642 = _766[0][_2358] >> uint(8);
                        uint _2729 = _2640 >> uint(8);
                        uint _2652 = _2729 | ((_2642 & 255u) << uint(24));
                        uint _2775 = _2652 >> uint(8);
                        uint _2664 = _2775 | (((_2642 >> uint(8)) & 255u) << uint(24));
                        uint4 _2376 = _2368 + uint4(uint(((abs(int(_2404) - _2679) + abs(int(_2416) - _2689)) + abs(int((_766[0][_2351] >> uint(16)) & 255u) - _2700)) + abs(int((_766[0][_2351] >> uint(24)) & 255u) - _2711)), uint(((abs(int(_2640 & 255u) - _2679) + abs(int(_2729 & 255u) - _2689)) + abs(int((_2640 >> uint(16)) & 255u) - _2700)) + abs(int((_2640 >> uint(24)) & 255u) - _2711)), uint(((abs(int(_2652 & 255u) - _2679) + abs(int(_2775 & 255u) - _2689)) + abs(int((_2652 >> uint(16)) & 255u) - _2700)) + abs(int((_2652 >> uint(24)) & 255u) - _2711)), uint(((abs(int(_2664 & 255u) - _2679) + abs(int((_2664 >> uint(8)) & 255u) - _2689)) + abs(int((_2664 >> uint(16)) & 255u) - _2700)) + abs(int((_2664 >> uint(24)) & 255u) - _2711)));
                        _3267 = _2376;
                        _3266++;
                        continue;
                    }
                    int _2868 = _1476 * 4;
                    int2 _2933 = int2(_2868, _1480) - int2(8);
                    int2 _2959 = _2933 >> int2(31);
                    uint2 _2965 = uint2((_2933 + _2959) ^ _2959);
                    uint _2945 = uint(_1480 << 4);
                    _662[0][_1480][_1476] = (_3267.x << uint(16)) | ((((_2965.y << uint(12)) | (_2965.x << uint(8))) | _2945) | uint(_2868));
                    int _2886 = _2868 + 1;
                    int2 _2973 = int2(_2886, _1480) - int2(8);
                    int2 _2999 = _2973 >> int2(31);
                    uint2 _3005 = uint2((_2973 + _2999) ^ _2999);
                    _662[1][_1480][_1476] = (_3267.y << uint(16)) | ((((_3005.y << uint(12)) | (_3005.x << uint(8))) | _2945) | uint(_2886));
                    int _2903 = _2868 + 2;
                    int2 _3013 = int2(_2903, _1480) - int2(8);
                    int2 _3039 = _3013 >> int2(31);
                    uint2 _3045 = uint2((_3013 + _3039) ^ _3039);
                    _662[2][_1480][_1476] = (_3267.z << uint(16)) | ((((_3045.y << uint(12)) | (_3045.x << uint(8))) | _2945) | uint(_2903));
                    int _2920 = _2868 + 3;
                    int2 _3053 = int2(_2920, _1480) - int2(8);
                    int2 _3079 = _3053 >> int2(31);
                    uint2 _3085 = uint2((_3053 + _3079) ^ _3079);
                    _662[3][_1480][_1476] = (_3267.w << uint(16)) | ((((_3085.y << uint(12)) | (_3085.x << uint(8))) | _2945) | uint(_2920));
                    threadgroup_barrier(mem_flags::mem_threadgroup);
                    uint _3111 = _662[0][_1480][_1476];
                    uint _3113 = _662[1][_1480][_1476];
                    uint _3124 = _662[2][_1480][_1476];
                    uint _3126 = _662[3][_1480][_1476];
                    uint _3170 = simd_min(min(min(_3111, _3113), min(_3124, _3126)));
                    bool _3134 = gl_SubgroupSize == 32u;
                    uint _3269;
                    if (_3134)
                    {
                        int _3137 = int(gl_LocalInvocationIndex) >> int(5u);
                        bool _3176 = simd_is_first();
                        if (_3176)
                        {
                            _713[_3137] = _3170;
                        }
                        threadgroup_barrier(mem_flags::mem_threadgroup);
                        _3269 = min(_3170, _713[_3137 ^ 1]);
                    }
                    else
                    {
                        _3269 = _3170;
                    }
                    uint _3187 = _3269 & 15u;
                    uint _3191 = _3269 >> uint(4);
                    uint _3231 = simd_sum((_1490 != _1391) ? 0u : _2051);
                    uint _3276;
                    if (_3134)
                    {
                        int _3213 = int(gl_LocalInvocationIndex) >> int(5u);
                        bool _3237 = simd_is_first();
                        if (_3237)
                        {
                            _640[_3213] = _3231;
                        }
                        threadgroup_barrier(mem_flags::mem_threadgroup);
                        _3276 = _3231 + _640[_3213 ^ 1];
                    }
                    else
                    {
                        _3276 = _3231;
                    }
                    _441.write(select(_3524 + int2(int(_3187) - 8, int(_3191 & 15u) - 8), int2(0), bool2((_404._m1 == 0u) && (_3276 <= (_3269 >> 16u)))).xyyy, uint2(_1379));
                    _3403 = _3426;
                    _3403.x = _1374 + 1;
                    _3426 = _3403;
                    continue;
                }
                else
                {
                    break;
                }
            }
        }
        break;
    } while(false);
}

