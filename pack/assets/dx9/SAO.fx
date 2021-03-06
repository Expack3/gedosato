/**
 \file SAO_AO.pix
 \author Morgan McGuire and Michael Mara, NVIDIA Research

 Reference implementation of the Scalable Ambient Obscurance (SAO) screen-space ambient obscurance algorithm. 
 
 The optimized algorithmic structure of SAO was published in McGuire, Mara, and Luebke, Scalable Ambient Obscurance,
 <i>HPG</i> 2012, and was developed at NVIDIA with support from Louis Bavoil.

 The mathematical ideas of AlchemyAO were first described in McGuire, Osman, Bukowski, and Hennessy, The 
 Alchemy Screen-Space Ambient Obscurance Algorithm, <i>HPG</i> 2011 and were developed at 
 Vicarious Visions.  
 
 DX11 HLSL port by Leonardo Zide of Treyarch

 Open Source under the "BSD" license: http://www.opensource.org/licenses/bsd-license.php

 Copyright (c) 2011-2012, NVIDIA
 All rights reserved.

 Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

 Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
 Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

  */

//////////////////////////////////////////////////////// TWEAKABLE VALUES ////////////////////////////////////////////////////////////

//#define SHOW_SSAO

/** manual nearZ/farZ values to compensate the fact we do not have access to the real projection matrix from the game */
static const float nearZ = 1.0;
static const float farZ = 18.0;

/** intensity : darkending factor, e.g., 1.0 */
/** aoClamp : brightness fine-tuning (the higher the darker) */
#ifdef SSAO_STRENGTH_LOW
float intensity = 0.3;
float aoClamp = 0.16;
#endif

#ifdef SSAO_STRENGTH_MEDIUM
float intensity = 0.4;
float aoClamp = 0.26;
#endif

#ifdef SSAO_STRENGTH_HIGH
float intensity = 0.6;
float aoClamp = 0.40;
#endif

/** Quality */
#define NUM_SAMPLES (9)

// If using depth mip levels, the log of the maximum pixel offset before we need to switch to a lower 
// miplevel to maintain reasonable spatial locality in the cache
// If this number is too small (< 3), too many taps will land in the same pixel, and we'll get bad variance that manifests as flashing.
// If it is too high (> 5), we'll get bad performance because we're not using the MIP levels effectively
#define LOG_MAX_OFFSET 3

// This must be less than or equal to the MAX_MIP_LEVEL defined in SSAO.cpp
#define MAX_MIP_LEVEL (5)

//comment this line to not take pixel brightness into account (the higher the more AO will blend into bright surfaces)
#define LUMINANCE_CONSIDERATION
extern float luminosity_threshold = 0.7;

/** Used for preventing AO computation on the sky (at infinite depth) and defining the CS Z to bilateral depth key scaling.
This need not match the real far plane*/
#define FAR_PLANE_Z (17.6)

/** World-space AO radius in scene units (r).  e.g., 1.0m */
static const float radius = 1.0;
/** radius*radius*/
static const float radius2 = (radius*radius);

/** Bias to avoid AO in smooth corners, e.g., 0.01m */
static const float bias = 0.02f;

/** The height in pixels of a 1m object if viewed from 1m away.
You can compute it from your projection matrix.  The actual value is just
a scale factor on radius; you can simply hardcode this to a constant (~500)
and make your radius value unitless (...but resolution dependent.)  */
static const float projScale = 1.2f;

/** Increase to make edges crisper. Decrease to reduce temporal flicker. */
#define EDGE_SHARPNESS     (0.2)

/** Step in 2-pixel intervals since we already blurred against neighbors in the
first AO pass.  This constant can be increased while R decreases to improve
performance at the expense of some dithering artifacts.

Morgan found that a scale of 3 left a 1-pixel checkerboard grid that was
unobjectionable after shading was applied but eliminated most temporal incoherence
from using small numbers of sample taps.
*/
#define SCALE               (2)

/** Filter radius in pixels. This will be multiplied by SCALE. */
#define R                   (6)

///////////////////////////////////////////////////END OF TWEAKABLE VALUES ///////////////////////////////////////////////////////////

static const int ROTATIONS[] = { 1, 1, 2, 3, 2, 5, 2, 3, 2,
3, 3, 5, 5, 3, 4, 7, 5, 5, 7,
9, 8, 5, 5, 7, 7, 7, 8, 5, 8,
11, 12, 7, 10, 13, 8, 11, 8, 7, 14,
11, 11, 13, 12, 13, 19, 17, 13, 11, 18,
19, 11, 11, 14, 17, 21, 15, 16, 17, 18,
13, 17, 11, 17, 19, 18, 25, 18, 19, 19,
29, 21, 19, 27, 31, 29, 21, 18, 17, 29,
31, 31, 23, 18, 25, 26, 25, 23, 19, 34,
19, 27, 21, 25, 39, 29, 17, 21, 27 };

// This is the number of turns around the circle that the spiral pattern makes.  This should be prime to prevent
// taps from lining up.  This particular choice was tuned for NUM_SAMPLES == 9
static const int NUM_SPIRAL_TURNS = ROTATIONS[NUM_SAMPLES-1];

#ifndef USE_SRGB
#define USE_SRGB true
#endif

extern bool isBlurHorizontal;

texture2D depthTex2D;
sampler depthSampler = sampler_state
{
	texture = <depthTex2D>;
	MinFilter = POINT;
	MagFilter = POINT;
	MipFilter = POINT;
	AddressU  = Mirror;
	AddressV  = Mirror;
	SRGBTexture=FALSE;
};

texture2D frameTex2D;
sampler frameSampler = sampler_state
{
	texture = <frameTex2D>;
	MinFilter = LINEAR;
	MagFilter = LINEAR;
	MipFilter = LINEAR;
	AddressU  = Clamp;
	AddressV  = Clamp;
	SRGBTexture = USE_SRGB;
};

texture2D prevPassTex2D;
sampler passSampler = sampler_state
{
	texture = <prevPassTex2D>;
	MinFilter = LINEAR;
	MagFilter = LINEAR;
	MipFilter = LINEAR;
	AddressU  = Clamp;
	AddressV  = Clamp;
	SRGBTexture=FALSE;
};

texture2D noiseTexture < string filename = "RandomNoiseB.dds"; >;
sampler2D noiseSampler = sampler_state {
	texture = <noiseTexture>;
 
	AddressU = WRAP;
	AddressV = WRAP;
 
	MINFILTER = LINEAR;
	MAGFILTER = LINEAR;
	MIPFILTER = LINEAR;
};

struct VSOUT
{
	float4 vertPos : POSITION0;
	float2 UVCoord : TEXCOORD0;
};

struct VSIN
{
	float4 vertPos : POSITION0;
	float2 UVCoord : TEXCOORD0;
};


VSOUT FrameVS(VSIN IN) {
	VSOUT OUT = (VSOUT)0.0f;
 
	OUT.vertPos = IN.vertPos;
	OUT.UVCoord = IN.UVCoord;
 
	return OUT;
}

/** Reconstruct camera-space P.xyz from screen-space S = (x, y) in
pixels and camera-space z < 0.  Assumes that the upper-left pixel center
is at (0.5, 0.5) [but that need not be the location at which the sample tap
was placed!]
*/
float3 reconstructCSPosition(float2 S, float z)
{
	// return float3((S.xy * projInfo.xy + projInfo.zw) * z, z);
	return float3(S, z);
}

/** Reconstructs screen-space unit normal from screen-space position */
float3 reconstructCSFaceNormal(float3 C)
{
    return normalize(cross(ddy(C), ddx(C)));
}

/** Returns a unit vector and a screen-space radius for the tap on a unit disk (the caller should scale by the actual disk radius) */
float2 tapLocation(int sampleNumber, float spinAngle, out float ssR)
{
    // Radius relative to ssR
    float alpha = float(sampleNumber + 0.5) * (1.0 / NUM_SAMPLES);
    float angle = alpha * (NUM_SPIRAL_TURNS * 6.28) + spinAngle;

    ssR = alpha;
    float sin_v, cos_v;
    sincos(angle, sin_v, cos_v);
    return float2(cos_v, sin_v);
}

/** Used for packing Z into the GB channels */
float CSZToKey(float z)
{
    return clamp(z * (1.0 / FAR_PLANE_Z), 0.0, 1.0);
}

/** "camera-space z < 0" */
float LinearizeDepth(float depth)
{
	return rcp(depth * ((farZ - nearZ) / (-farZ * nearZ)) + farZ / (farZ * nearZ));
}

/** Read the camera-space position of the point at screen-space pixel ssP */
float3 getPosition(float2 ssP)
{
    float3 P;

    P.z = tex2D(depthSampler, ssP).r;

    // Offset to pixel center
	P = reconstructCSPosition(float2(ssP) + float2(0.5, 0.5), P.z);
    return P;
}

/** Read the camera-space position of the point at screen-space pixel ssP + unitOffset * ssR.  Assumes length(unitOffset) == 1 */
float3 getOffsetPosition(float2 ssC, float2 unitOffset, float ssR)
{
	// Derivation:
	//  mipLevel = floor(log(ssR / MAX_OFFSET));
	int mipLevel = clamp((int)floor(log2(ssR)) - LOG_MAX_OFFSET, 0, MAX_MIP_LEVEL);
	//int mipLevel = 4;

    float2 ssP = float2(ssR*unitOffset) + ssC;

    float3 P;

	// Divide coordinate by 2^mipLevel
	//P.z = tex2Dlod(depthSampler, float4(ssP * pow(0.5, -mipLevel), 0, mipLevel)).r;
	P.z = tex2D(depthSampler, ssP * pow(0.5, -mipLevel)).r;

    // Offset to pixel center
	P = reconstructCSPosition(float2(ssP) + float2(0.5, 0.5), P.z);

    return P;
}

/** Compute the occlusion due to sample with index \a i about the pixel at \a ssC that corresponds
    to camera-space point \a C with unit normal \a n_C, using maximum screen-space sampling radius \a ssDiskRadius 

    Note that units of H() in the HPG12 paper are meters, not
    unitless.  The whole falloff/sampling function is therefore
    unitless.  In this implementation, we factor out (9 / radius).

    Four versions of the falloff function are implemented below
*/
float sampleAO(in float2 ssC, in float3 C, in float3 n_C, in float ssDiskRadius, in int tapIndex, in float randomPatternRotationAngle)
{
    // Offset on the unit disk, spun for this pixel
    float ssR;
    float2 unitOffset = tapLocation(tapIndex, randomPatternRotationAngle, ssR);
    ssR *= ssDiskRadius;

    // The occluding point in camera space
    float3 Q = getOffsetPosition(ssC, unitOffset, ssR);

    float3 v = Q - C;

    float vv = dot(v, v);
    float vn = dot(v, n_C);

    const float epsilon = 0.02;   // Original implementation : epsilon = 0.01;

    // A: From the HPG12 paper
    // Note large epsilon to avoid overdarkening within cracks
    //return float(vv < radius2) * max((vn - bias) / (epsilon + vv), 0.0) * radius2 * 0.6;

    // B: Smoother transition to zero (lowers contrast, smoothing out corners). [Recommended]
    //float f = max(radius2 - vv, 0.0); return f * f * f * max((vn - bias) / (epsilon + vv), 0.0);
	return float(vv < radius2) * max((vn - bias) / (epsilon + vv), 0.0) * radius2 * 0.6;

    // C: Medium contrast (which looks better at high radii), no division.  Note that the 
    // contribution still falls off with radius^2, but we've adjusted the rate in a way that is
    // more computationally efficient and happens to be aesthetically pleasing.
    //return 4.0 * max(1.0 - vv * 1.0 / radius2, 0.0) * max(vn - bias, 0.0);

    // D: Low contrast, no division operation
    //return 2.0 * float(vv < radius * radius) * max(vn - bias, 0.0);
}

/** Used for packing Z into the GB channels */
void packKey(float key, out float2 p)
{
    // Round to the nearest 1/256.0
    float temp = floor(key * 256.0);
    // Integer part
    p.x = temp * (1.0 / 256.0);
    // Fractional part
    p.y = key * 256.0 - temp;
}

float unpackKey(float2 p)
{
    return p.x * (256.0 / 257.0) + p.y * (1.0 / 257.0);
}

float4 reconstructCSZPass(VSOUT IN) : COLOR0
{
	return float4(LinearizeDepth(tex2D(depthSampler, IN.UVCoord).r), 0, 0, 0);
}

//extern int previousMIPNumber;

float4 minifyPass(VSOUT IN) : COLOR0
{
	// int2 ssP = pixel.texCoords * float2(renderTargetSize[SIZECONST_WIDTH], renderTargetSize[SIZECONST_HEIGHT]);
	float2 ssP = IN.UVCoord;

	// Rotated grid subsampling to avoid XY directional bias or Z precision bias while downsampling
	// fragment.color = source.Load(int3(ssP * 2 + int2((ssP.y & 1) ^ 1, (ssP.x & 1) ^ 1), 0)); // DX11
	// return tex2Dlod(depthSampler, float4(ssP * 2 + float2(((ssP.y - floor(ssP.y)) * 2) != 1, ((ssP.x - floor(ssP.x)) * 2) != 1), 0, previousMIPNumber));

	// Plain dumb Linear mip-map instead of Rotated grid subsampling. (I can't make that one work unfortunately :/)
	return float4(tex2Dlod(depthSampler, float4(IN.UVCoord, 0, 0)).r, 0, 0, 0);
}

#define visibility      output.r
#define bilateralKey    output.gb

float4 SSAOCalculate(VSOUT IN) : COLOR0
{
	//return tex2Dlod(depthSampler, float4(IN.UVCoord, 0, 3));
	
    float4 output = float4(1,1,1,1);
  
    // Pixel being shaded 
    float2 ssC = IN.UVCoord;

    // World space point being shaded
    float3 C = getPosition(ssC);
	//return float4(C, 1.0);
	
	bool earlyOut = C.z > FAR_PLANE_Z || C.z < 0.4f || any(ssC >= (SCREEN_SIZE - 8));
    [branch]
    if(earlyOut)
    {
        return output;
    }

    packKey(CSZToKey(C.z), bilateralKey);

    // Hash function used in the HPG12 AlchemyAO paper (Note from Boulotaur2024 : no hash in DX9 :/)
	float randomPatternRotationAngle = tex2D(noiseSampler, ssC*12.0).x * 1000.0;
	//float randomPatternRotationAngle = (3 * ssC.x != ssC.y + ssC.x * ssC.y) * 10;

    // Reconstruct normals from positions. These will lead to 1-pixel black lines
    // at depth discontinuities, however the blur will wipe those out so they are not visible
    // in the final image.
	float3 n_C = reconstructCSFaceNormal(C);
	//return float4(n_C, 1.0);

    // Choose the screen-space sample radius
    float ssDiskRadius = projScale * radius / max(C.z,0.1f);

    float sum = 0.0;
    for (int i = 0; i < NUM_SAMPLES; ++i) 
    {
         sum += sampleAO(ssC, C, n_C, ssDiskRadius, i, randomPatternRotationAngle);
    }
	
    const float temp = radius2 * radius;
    sum /= temp * temp;

    float A = max(0.0f, 1.0f - sum * intensity * (5.0f / NUM_SAMPLES));

	// Bilateral box-filter over a quad for free, respecting depth edges
	// (the difference that this makes is subtle)
	if (abs(ddx(C.z)) < 0.02) {
		A -= ddx(A) * (((ssC.x - floor(ssC.x)) * 2) - 0.5);  // ssC.x & 1 -> (ssC.x - floor(ssC.x)) * 2 (McGuire tip)
	}
	if (abs(ddy(C.z)) < 0.02) {
		A -= ddy(A) * (((ssC.y - floor(ssC.y)) * 2) - 0.5);
	}

	visibility = lerp(1.0, A, aoClamp);
	//return float4(visibility, visibility, visibility, 1.0);
	
    return output;
}

//////////////////////////////////////////////////////////////////////////////////////////////

/** Type of data to read from source.  This macro allows
the same blur shader to be used on different kinds of input data. */
#define VALUE_TYPE        float

/** Swizzle to use to extract the channels of source. This macro allows
the same blur shader to be used on different kinds of input data. */
#define VALUE_COMPONENTS   r

#define VALUE_IS_KEY       0

/** Channel encoding the bilateral key value (which must not be the same as VALUE_COMPONENTS) */
#define KEY_COMPONENTS     gb

// Gaussian coefficients
static const float gaussian[] =
//	{ 0.356642, 0.239400, 0.072410, 0.009869 };
//	{ 0.398943, 0.241971, 0.053991, 0.004432, 0.000134 };  // stddev = 1.0
//    { 0.153170, 0.144893, 0.122649, 0.092902, 0.062970 };  // stddev = 2.0
{ 0.111220, 0.107798, 0.098151, 0.083953, 0.067458, 0.050920, 0.036108 }; // stddev = 3.0

#define  result         output.VALUE_COMPONENTS
#define  keyPassThrough output.KEY_COMPONENTS

float4 BlurBL(VSOUT IN) : COLOR0
{
	float4 output = float4(1,1,1,1);

	float2 ssC = IN.UVCoord;

	float4 temp = tex2Dlod(passSampler, float4(ssC,0,0));

	keyPassThrough = temp.KEY_COMPONENTS;
	float key = unpackKey(keyPassThrough);

	float sum = temp.r;

	if (key >= 0.999) { 
		// Sky pixel (if you aren't using depth keying, disable this test)
		result = sum;
		return output;
	}

	// Base weight for depth falloff.  Increase this for more blurriness,
	// decrease it for better edge discrimination
	float BASE = gaussian[0];
	float totalWeight = BASE;
	sum *= totalWeight; 

	for (int r = -R; r <= R; ++r) {
		// We already handled the zero case above.  This loop should be unrolled and the branch discarded
		if (r != 0) {
            float2 axis = (isBlurHorizontal) ? float2(1, 0) : float2(0, 1);

			temp = tex2Dlod(passSampler, float4(ssC + axis * PIXEL_SIZE * (r * SCALE),0,0) );
			float tapKey = unpackKey(temp.gb);
			float value  = temp.r;

			// spatial domain: offset gaussian tap
			int index = r; if (index<0) index = -index;
			float weight = 0.3 + gaussian[index];

			// range domain (the "bilateral" weight). As depth difference increases, decrease weight.
			weight *= max(0.0, 1.0 - (2000.0 * EDGE_SHARPNESS) * abs(tapKey - key));

			sum += value * weight;
			totalWeight += weight;
		} 
	}

	const float epsilon = 0.0001;
	result = sum / (totalWeight + epsilon);

	return output;
}

float4 combine( VSOUT IN ) : COLOR0 {
	float4 color = tex2D(frameSampler, IN.UVCoord);
	float ao = tex2D(passSampler, IN.UVCoord).r;

	#ifdef SHOW_SSAO
	return float4(ao,ao,ao,1);
	#endif	
	
	#ifdef LUMINANCE_CONSIDERATION
	float luminance = (color.r*0.2125f)+(color.g*0.7154f)+(color.b*0.0721f);
	float white = 1.0f;
	float black = 0.0f;

	luminance = clamp(max(black,luminance-luminosity_threshold)+max(black,luminance-luminosity_threshold)+max(black,luminance-luminosity_threshold),0.0,1.0);
	ao = lerp(ao,white,luminance);
	#endif	

	color.rgb *= ao;
	return color;
}

technique t0
{
	pass p0
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 reconstructCSZPass();
	}
	pass p1
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 minifyPass();
	}
	pass p2
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 SSAOCalculate();
	}
	pass p3
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 BlurBL();	
	}
	pass p4
	{
		VertexShader = compile vs_3_0 FrameVS();
		PixelShader = compile ps_3_0 combine();
	}
}