#version 430 core

#define saturate(x)        clamp(x, 0.0, 1.0)
#define PI  3.141592653
in vec2 TexCoords;


uniform mat4 materialParams_reprojection;
uniform float materialParams_alpha;
uniform vec2 materialParams_jitter;
uniform vec4 materialParams_filterWeights[9];

out vec4 FragColor;

uniform sampler2D materialParams_color;
uniform sampler2D materialParams_depth;
uniform sampler2D materialParams_history;


const bool materialConstants_upscaling = false;
const bool materialConstants_historyReprojection = true;
const bool materialConstants_filterHistory = true;
const bool materialConstants_filterInput = true;
const int materialConstants_boxClipping = 0;
const int materialConstants_boxType = 1;
const bool materialConstants_useYCoCg = false;
const bool materialConstants_preventFlickering = false;
const float materialConstants_varianceGamma = 1.0;

/* Clipping box type */

// min/max neighborhood
#define BOX_TYPE_AABB           0
// Variance based neighborhood
#define BOX_TYPE_VARIANCE       1
// uses both min/max and variance
#define BOX_TYPE_AABB_VARIANCE  2

/* Clipping algorithm */

// accurate box clipping
#define BOX_CLIPPING_ACCURATE   0
// clamping instead of clipping
#define BOX_CLIPPING_CLAMP      1
// no clipping (for debugging only)
#define BOX_CLIPPING_NONE       2


float max3(const vec3 v) 
{
    return max(v.x, max(v.y, v.z));
}


float rcp(float x) 
{
    return 1.0 / x;
}

float luminance(const vec3 linear) 
{
    return dot(linear, vec3(0.2126, 0.7152, 0.0722));
}

float lumaRGB(const vec3 c) 
{
    return luminance(c);
}

float lumaYCoCg(const vec3 c) 
{
    return c.x;
}

float luma(const vec3 c) 
{
    return materialConstants_useYCoCg ? lumaYCoCg(c) : lumaRGB(c);
}

vec3 tonemap(const vec3 c) 
{
    return c * rcp(1.0 + max3(c));
}

vec4 tonemap(const vec4 c) 
{
    return vec4(c.rgb * rcp(1.0 + max3(c.rgb)), c.a);
}

vec3 tonemap(const float w, const vec3 c) 
{
    return c * (w * rcp(1.0 + max3(c)));
}

vec4 tonemap(const float w, const vec4 c) 
{

    return vec4(c.rgb * (w * rcp(1.0 + max3(c.rgb))), c.a);
}

vec3 untonemap(const vec3 c) 
{
    const float epsilon = 1.0 / 65504.0;
    return c * rcp(max(epsilon, 1.0 - max3(c)));
}

vec3 RGB_YCoCg(const vec3 c) 
{
    float Y  = dot(c.rgb, vec3( 1, 2,  1) * 0.25);
    float Co = dot(c.rgb, vec3( 2, 0, -2) * 0.25);
    float Cg = dot(c.rgb, vec3(-1, 2, -1) * 0.25);
    return vec3(Y, Co, Cg);
}

vec3 YCoCg_RGB(const vec3 c) 
{
    float Y  = c.x;
    float Co = c.y;
    float Cg = c.z;
    float r = Y + Co - Cg;
    float g = Y + Cg;
    float b = Y - Co - Cg;
    return vec3(r, g, b);
}

// clip the (c, h) segment to a box
vec4 clipToBox(const int quality,
        const vec3 boxmin,  const vec3 boxmax, const vec4 c, const vec4 h) 
{
    const float epsilon = 0.0001;

    if (quality == BOX_CLIPPING_ACCURATE) {
        vec4 r = c - h;
        vec3 ir = 1.0 / (epsilon + r.rgb);
        vec3 rmax = (boxmax - h.rgb) * ir;
        vec3 rmin = (boxmin - h.rgb) * ir;
        vec3 imin = min(rmax, rmin);
        return h + r * saturate(max3(imin));
    } else if (quality == BOX_CLIPPING_CLAMP) {
        return vec4(clamp(h.rgb, boxmin, boxmax), h.a);
    }
    return h;
}


vec4 sampleTextureCatmullRom(const sampler2D tex, const highp vec2 uv, const highp vec2 texSize) 
{
    // We're going to sample a a 4x4 grid of texels surrounding the target UV coordinate.
    // We'll do this by rounding down the sample location to get the exact center of our "starting"
    // texel. The starting texel will be at location [1, 1] in the grid, where [0, 0] is the
    // top left corner.

    highp vec2 samplePos = uv * texSize;
    highp vec2 texPos1 = floor(samplePos - 0.5) + 0.5;

    // Compute the fractional offset from our starting texel to our original sample location,
    // which we'll feed into the Catmull-Rom spline function to get our filter weights.
    highp vec2 f = samplePos - texPos1;
    highp vec2 f2 = f * f;
    highp vec2 f3 = f2 * f;

    // Compute the Catmull-Rom weights using the fractional offset that we calculated earlier.
    // These equations are pre-expanded based on our knowledge of where the texels will be located,
    // which lets us avoid having to evaluate a piece-wise function.
    vec2 w0 = f2 - 0.5 * (f3 + f);
    vec2 w1 = 1.5 * f3 - 2.5 * f2 + 1.0;
    vec2 w3 = 0.5 * (f3 - f2);
    vec2 w2 = 1.0 - w0 - w1 - w3;

    // Work out weighting factors and sampling offsets that will let us use bilinear filtering to
    // simultaneously evaluate the middle 2 samples from the 4x4 grid.
    vec2 w12 = w1 + w2;

    // Compute the final UV coordinates we'll use for sampling the texture
    highp vec2 texPos0 = texPos1 - vec2(1.0);
    highp vec2 texPos3 = texPos1 + vec2(2.0);
    highp vec2 texPos12 = texPos1 + w2 / w12;

    highp vec2 invTexSize = 1.0 / texSize;
    texPos0  *= invTexSize;
    texPos3  *= invTexSize;
    texPos12 *= invTexSize;

    float k0 = w12.x * w0.y;
    float k1 = w0.x  * w12.y;
    float k2 = w12.x * w12.y;
    float k3 = w3.x  * w12.y;
    float k4 = w12.x * w3.y;

    vec4 s[5];
    s[0] = textureLod(tex, vec2(texPos12.x, texPos0.y),  0.0);
    s[1] = textureLod(tex, vec2(texPos0.x,  texPos12.y), 0.0);
    s[2] = textureLod(tex, vec2(texPos12.x, texPos12.y), 0.0);
    s[3] = textureLod(tex, vec2(texPos3.x,  texPos12.y), 0.0);
    s[4] = textureLod(tex, vec2(texPos12.x, texPos3.y),  0.0);

    vec4 result =   k0 * s[0]
                  + k1 * s[1]
                  + k2 * s[2]
                  + k3 * s[3]
                  + k4 * s[4];

    result *= rcp(k0 + k1 + k2 + k3 + k4);

    // we could end-up with negative values
    result = max(vec4(0), result);

    return result;
}

void main() 
{
 
    highp vec4 uv = TexCoords.xyxy; // interpolated to pixel center
    if (materialConstants_historyReprojection) 
    {
        // read the depth buffer center sample for reprojection
        highp float depth = textureLod(materialParams_depth, uv.xy, 0.0).r;
        // reproject history to current frame
        uv.zw = uv.zw;
        highp vec4 q = materialParams_reprojection * vec4(uv.zw, depth, 1.0);
        uv.zw = (q.xy * (1.0 / q.w)) * 0.5 + 0.5;
        uv.zw = uv.zw;
    }

    // read center color and history samples
    vec4 history;
    if (materialConstants_filterHistory) 
    {
        history = sampleTextureCatmullRom(materialParams_history, uv.zw,
                vec2(textureSize(materialParams_history, 0)));
    } 
    else 
    {
        history = textureLod(materialParams_history, uv.zw, 0.0);
    }

    if (materialConstants_useYCoCg) 
    {
        history.rgb = RGB_YCoCg(history.rgb);
    }

    highp vec2 size = vec2(textureSize(materialParams_color, 0));
    highp vec2 p = (floor(uv.xy * size) + 0.5) / size;
    vec4 filtered = textureLod(materialParams_color, p, 0.0);

    vec3 s[9];
    if (materialConstants_filterInput || materialConstants_boxClipping != BOX_CLIPPING_NONE) 
    {
        s[0] = textureLodOffset(materialParams_color, p, 0.0, ivec2(-1, -1)).rgb;
        s[1] = textureLodOffset(materialParams_color, p, 0.0, ivec2( 0, -1)).rgb;
        s[2] = textureLodOffset(materialParams_color, p, 0.0, ivec2( 1, -1)).rgb;
        s[3] = textureLodOffset(materialParams_color, p, 0.0, ivec2(-1,  0)).rgb;
        s[4] = filtered.rgb;
        s[5] = textureLodOffset(materialParams_color, p, 0.0, ivec2( 1,  0)).rgb;
        s[6] = textureLodOffset(materialParams_color, p, 0.0, ivec2(-1,  1)).rgb;
        s[7] = textureLodOffset(materialParams_color, p, 0.0, ivec2( 0,  1)).rgb;
        s[8] = textureLodOffset(materialParams_color, p, 0.0, ivec2( 1,  1)).rgb;
        if (materialConstants_useYCoCg) 
        {
            for (int i = 0; i < 9; i++) 
            {
                s[i] = RGB_YCoCg(s[i]);
            }
        }
    }

    vec2 subPixelOffset = p - uv.xy;  // +/- [0.25, 0.25]
    float confidence = materialConstants_upscaling ? 0.0 : 1.0;

    if (materialConstants_filterInput) 
    {
        // unjitter/filter input
        // figure out which set of coeficients to use
        filtered = vec4(0, 0, 0, filtered.a);
        if (materialConstants_upscaling) 
        {
            int jxp = subPixelOffset.y > 0.0 ? 3 : 0;
            int jxn = subPixelOffset.y > 0.0 ? 2 : 1;
            int j   = subPixelOffset.x > 0.0 ? jxp : jxn;
            for (int i = 0; i < 9; i++) 
            {
                float w = materialParams_filterWeights[i][j];
                filtered.rgb += s[i] * w;
                confidence = max(confidence, w);
            }
        } 
        else 
        {
            for (int i = 0; i < 9; i++) 
            {
                float w = materialParams_filterWeights[i][0];
                filtered.rgb += s[i] * w;
            }
        }
    } 
    else 
    {
        if (materialConstants_useYCoCg) 
        {
            filtered.rgb = RGB_YCoCg(filtered.rgb);
        }
        if (materialConstants_upscaling) 
        {
            confidence = float(materialParams_jitter.x * subPixelOffset.x > 0.0 &&
                               materialParams_jitter.y * subPixelOffset.y > 0.0);
        }
    }

    // build the history clamping box
    if (materialConstants_boxClipping != BOX_CLIPPING_NONE) 
    {
        vec3 boxmin;
        vec3 boxmax;
        if (materialConstants_boxType == BOX_TYPE_AABB ||
                materialConstants_boxType == BOX_TYPE_AABB_VARIANCE) 
        {
            boxmin = min(s[4], min(min(s[1], s[3]), min(s[5], s[7])));
            boxmax = max(s[4], max(max(s[1], s[3]), max(s[5], s[7])));
            vec3 box9min = min(boxmin, min(min(s[0], s[2]), min(s[6], s[8])));
            vec3 box9max = max(boxmax, max(max(s[0], s[2]), max(s[6], s[8])));
            // round the corners of the 3x3 box
            boxmin = (boxmin + box9min) * 0.5;
            boxmax = (boxmax + box9max) * 0.5;
        }

        if (materialConstants_boxType == BOX_TYPE_VARIANCE ||
                materialConstants_boxType == BOX_TYPE_AABB_VARIANCE) 
        {
            // "An Excursion in Temporal Supersampling" by Marco Salvi
            highp vec3 m0 = s[4];// conversion to highp
            highp vec3 m1 = m0 * m0;
            // we use only 5 samples instead of all 9
            for (int i = 1; i < 9; i+=2) 
            {
                highp vec3 c = s[i];// conversion to highp
                m0 += c;
                m1 += c * c;
            }
            highp vec3 a0 = m0 * (1.0 / 5.0);
            highp vec3 a1 = m1 * (1.0 / 5.0);
            highp vec3 sigma = sqrt(a1 - a0 * a0);
            if (materialConstants_boxType == BOX_TYPE_VARIANCE) 
            {
                boxmin = a0 - materialConstants_varianceGamma * sigma;
                boxmax = a0 + materialConstants_varianceGamma * sigma;
            } 
            else 
            {
                // intersect both bounding boxes
                boxmin = max(boxmin, a0 - materialConstants_varianceGamma * sigma);
                boxmax = min(boxmax, a0 + materialConstants_varianceGamma * sigma);
            }
        }
        // history clamping
        history = clipToBox(materialConstants_boxClipping, boxmin, boxmax, filtered, history);
    }

    float alpha = materialParams_alpha * confidence;
    if (materialConstants_preventFlickering) 
    {
        // [Lottes] prevents flickering by modulating the blend weight by the difference in luma
        float lumaColor = luma(filtered.rgb);
        float lumaHistory = luma(history.rgb);
        float diff = 1.0 - abs(lumaColor - lumaHistory) / (0.001 + max(lumaColor, lumaHistory));
        alpha *= diff * diff;
    }

    // go back to RGB space before tonemapping
    if (materialConstants_useYCoCg) 
    {
        filtered.rgb = YCoCg_RGB(filtered.rgb);
        history.rgb = YCoCg_RGB(history.rgb);
    }

    // tonemap before mixing
    filtered.rgb = tonemap(filtered.rgb);
    history.rgb = tonemap(history.rgb);

    // combine history and current frame
    vec4 result = mix(history, filtered, alpha);

    // untonemap result
    result.rgb = untonemap(result.rgb);

    // store result (which will becomes new history)
    FragColor = result;


}
