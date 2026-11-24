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
#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct _134
{
    int2 _m0;
    uint _m1;
    uint _m2;
    uint _m3;
    uint _m4;
    float2 _m5;
};

kernel void CS(constant _134& _136 [[buffer(0)]], texture2d<float> _151 [[texture(0)]], texture2d<uint, access::write> _160 [[texture(1)]], uint3 gl_GlobalInvocationID [[thread_position_in_grid]])
{
    int2 _371 = int2(int3(gl_GlobalInvocationID).xy);
    for (int _692 = 0; _692 < 2; _692++)
    {
        for (int _693 = 0; _693 < 2; _693++)
        {
            int2 _424 = (_371 * int2(2)) + int2(_693, _692);
            float4 _479 = _151.read(uint2(uint2(_424)), 0);
            float3 _429 = _479.xyz;
            float _697;
            if (_136._m4 == 0u)
            {
                _697 = ((0.2125999927520751953125 * _479.x) + (0.715200006961822509765625 * _479.y)) + (0.072200000286102294921875 * _479.z);
            }
            else
            {
                float _698;
                if (_136._m4 == 1u)
                {
                    float3 _527 = powr(_429, float3(0.01268330030143260955810546875));
                    float3 _513 = powr(fast::clamp(_527 - float3(0.835937976837158203125), float3(0.0), float3(1.0)) / (float3(18.85160064697265625) - (float3(18.6875) * _527)), float3(6.277390003204345703125)) * (10000.0 / _136._m5.y);
                    float _579 = ((0.2626999914646148681640625 * _513.x) + (0.677999973297119140625 * _513.y)) + (0.0593000017106533050537109375 * _513.z);
                    float _696;
                    if (_579 <= 0.008856452070176601409912109375)
                    {
                        _696 = _579 * 903.29632568359375;
                    }
                    else
                    {
                        _696 = (powr(_579, 0.3333333432674407958984375) * 116.0) - 16.0;
                    }
                    _698 = _696 * 0.00999999977648258209228515625;
                }
                else
                {
                    float _699;
                    if (_136._m4 == 2u)
                    {
                        float3 _641 = (_429 - float3(_136._m5.x * 0.012500000186264514923095703125)) / float3((_136._m5.y - _136._m5.x) * 0.012500000186264514923095703125);
                        float _663 = ((0.2125999927520751953125 * _641.x) + (0.715200006961822509765625 * _641.y)) + (0.072200000286102294921875 * _641.z);
                        float _695;
                        if (_663 <= 0.008856452070176601409912109375)
                        {
                            _695 = _663 * 903.29632568359375;
                        }
                        else
                        {
                            _695 = (powr(_663, 0.3333333432674407958984375) * 116.0) - 16.0;
                        }
                        _699 = _695 * 0.00999999977648258209228515625;
                    }
                    else
                    {
                        _699 = 0.0;
                    }
                    _698 = _699;
                }
                _697 = _698;
            }
            _160.write(uint4(uint(_697 * 255.0)), uint2(_424));
        }
    }
}

