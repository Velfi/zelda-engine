// Source: https://gist.github.com/SoapyMan/1d32b56dd267e7cd9a2408047fd5c90c
// [src] https://github.com/ocornut/imgui/issues/123
// [src] https://github.com/ocornut/imgui/issues/55

#define IMGUI_DEFINE_MATH_OPERATORS
#include "imgui.h"
#include "imgui_internal.h"

#include <cmath>
#include <cstdio>
#include <vector>

namespace tween
{
enum TYPE
{
    LINEAR,

    QUADIN, // t^2
    QUADOUT,
    QUADINOUT,
    CUBICIN, // t^3
    CUBICOUT,
    CUBICINOUT,
    QUARTIN, // t^4
    QUARTOUT,
    QUARTINOUT,
    QUINTIN, // t^5
    QUINTOUT,
    QUINTINOUT,
    SINEIN, // sin(t)
    SINEOUT,
    SINEINOUT,
    EXPOIN, // 2^t
    EXPOOUT,
    EXPOINOUT,
    CIRCIN, // sqrt(1-t^2)
    CIRCOUT,
    CIRCINOUT,
    ELASTICIN, // exponentially decaying sine wave
    ELASTICOUT,
    ELASTICINOUT,
    BACKIN, // overshooting cubic easing: (s+1)*t^3 - s*t^2
    BACKOUT,
    BACKINOUT,
    BOUNCEIN, // exponentially decaying parabolic bounce
    BOUNCEOUT,
    BOUNCEINOUT,

    SINESQUARE,  // gapjumper's
    EXPONENTIAL, // gapjumper's
    SCHUBRING1,  // terry schubring's formula 1
    SCHUBRING2,  // terry schubring's formula 2
    SCHUBRING3,  // terry schubring's formula 3

    SINPI2, // tomas cepeda's
    SWING,  // tomas cepeda's & lquery's
};

static inline double ease(int easetype, double t)
{
    const double d = 1.0;
    const double pi = 3.1415926535897932384626433832795;
    const double pi2 = pi / 2.0;

    double p = t / d;

    switch (easetype)
    {
    default:
    case TYPE::LINEAR:
        return p;

    case TYPE::QUADIN:
        return p * p;

    case TYPE::QUADOUT:
        return -(p * (p - 2));

    case TYPE::QUADINOUT:
        return (p < 0.5) ? (2 * p * p) : ((-2 * p * p) + (4 * p) - 1);

    case TYPE::CUBICIN:
        return p * p * p;

    case TYPE::CUBICOUT: {
        const double f = (p - 1);
        return f * f * f + 1;
    }

    case TYPE::CUBICINOUT:
        if (p < 0.5)
            return 4 * p * p * p;
        else
        {
            const double f = ((2 * p) - 2);
            return 0.5 * f * f * f + 1;
        }

    case TYPE::QUARTIN:
        return p * p * p * p;

    case TYPE::QUARTOUT: {
        const double f = (p - 1);
        return f * f * f * (1 - p) + 1;
    }

    case TYPE::QUARTINOUT:
        if (p < 0.5)
            return 8 * p * p * p * p;
        else
        {
            const double f = (p - 1);
            return -8 * f * f * f * f + 1;
        }

    case TYPE::QUINTIN:
        return p * p * p * p * p;

    case TYPE::QUINTOUT: {
        const double f = (p - 1);
        return f * f * f * f * f + 1;
    }

    case TYPE::QUINTINOUT:
        if (p < 0.5)
            return 16 * p * p * p * p * p;
        else
        {
            const double f = ((2 * p) - 2);
            return 0.5 * f * f * f * f * f + 1;
        }

    case TYPE::SINEIN:
        return sin((p - 1) * pi2) + 1;

    case TYPE::SINEOUT:
        return sin(p * pi2);

    case TYPE::SINEINOUT:
        return 0.5 * (1 - cos(p * pi));

    case TYPE::CIRCIN:
        return 1 - sqrt(1 - (p * p));

    case TYPE::CIRCOUT:
        return sqrt((2 - p) * p);

    case TYPE::CIRCINOUT:
        if (p < 0.5)
            return 0.5 * (1 - sqrt(1 - 4 * (p * p)));
        else
            return 0.5 * (sqrt(-((2 * p) - 3) * ((2 * p) - 1)) + 1);

    case TYPE::EXPOIN:
        return (p == 0.0) ? p : pow(2, 10 * (p - 1));

    case TYPE::EXPOOUT:
        return (p == 1.0) ? p : 1 - pow(2, -10 * p);

    case TYPE::EXPOINOUT:
        if (p == 0.0 || p == 1.0)
            return p;
        if (p < 0.5)
            return 0.5 * pow(2, (20 * p) - 10);
        return -0.5 * pow(2, (-20 * p) + 10) + 1;

    case TYPE::ELASTICIN:
        return sin(13 * pi2 * p) * pow(2, 10 * (p - 1));

    case TYPE::ELASTICOUT:
        return sin(-13 * pi2 * (p + 1)) * pow(2, -10 * p) + 1;

    case TYPE::ELASTICINOUT:
        if (p < 0.5)
            return 0.5 * sin(13 * pi2 * (2 * p)) * pow(2, 10 * ((2 * p) - 1));
        return 0.5 * (sin(-13 * pi2 * ((2 * p - 1) + 1)) * pow(2, -10 * (2 * p - 1)) + 2);

    case TYPE::BACKIN: {
        const double s = 1.70158;
        return p * p * ((s + 1) * p - s);
    }

    case TYPE::BACKOUT: {
        const double s = 1.70158;
        p -= 1.0;
        return p * p * ((s + 1) * p + s) + 1;
    }

    case TYPE::BACKINOUT: {
        const double s = 1.70158 * 1.525;
        if (p < 0.5)
        {
            p *= 2;
            return 0.5 * p * p * (p * s + p - s);
        }
        p = p * 2 - 2;
        return 0.5 * (2 + p * p * (p * s + p + s));
    }

    case TYPE::BOUNCEIN:
        if ((1 - p) < 4 / 11.0)
            return 1 - ((121 * (1 - p) * (1 - p)) / 16.0);
        if ((1 - p) < 8 / 11.0)
            return 1 - (((363 / 40.0 * (1 - p) * (1 - p)) - (99 / 10.0 * (1 - p)) + 17 / 5.0));
        if ((1 - p) < 9 / 10.0)
            return 1 - (((4356 / 361.0 * (1 - p) * (1 - p)) - (35442 / 1805.0 * (1 - p)) + 16061 / 1805.0));
        return 1 - (((54 / 5.0 * (1 - p) * (1 - p)) - (513 / 25.0 * (1 - p)) + 268 / 25.0));

    case TYPE::BOUNCEOUT:
        if (p < 4 / 11.0)
            return (121 * p * p) / 16.0;
        if (p < 8 / 11.0)
            return (363 / 40.0 * p * p) - (99 / 10.0 * p) + 17 / 5.0;
        if (p < 9 / 10.0)
            return (4356 / 361.0 * p * p) - (35442 / 1805.0 * p) + 16061 / 1805.0;
        return (54 / 5.0 * p * p) - (513 / 25.0 * p) + 268 / 25.0;

    case TYPE::BOUNCEINOUT:
        if (p < 0.5)
            return 0.5 * (1 - ease(TYPE::BOUNCEOUT, 1 - p * 2));
        return 0.5 * ease(TYPE::BOUNCEOUT, (p * 2 - 1)) + 0.5;

    case TYPE::SINESQUARE: {
        const double a = sin(p * pi2);
        return a * a;
    }

    case TYPE::EXPONENTIAL:
        return 1 / (1 + exp(6 - 12 * p));

    case TYPE::SCHUBRING1:
        return 2 * (p + (0.5 - p) * fabs(0.5 - p)) - 0.5;

    case TYPE::SCHUBRING2: {
        const double p1 = 2 * (p + (0.5 - p) * fabs(0.5 - p)) - 0.5;
        const double p2 = 2 * (p1 + (0.5 - p1) * fabs(0.5 - p1)) - 0.5;
        return (p1 + p2) / 2;
    }

    case TYPE::SCHUBRING3: {
        const double p1 = 2 * (p + (0.5 - p) * fabs(0.5 - p)) - 0.5;
        return 2 * (p1 + (0.5 - p1) * fabs(0.5 - p1)) - 0.5;
    }

    case TYPE::SWING:
        return ((-cos(pi * p) * 0.5) + 0.5);

    case TYPE::SINPI2:
        return sin(p * pi2);
    }
}
} // namespace tween

namespace ImGui
{
static const float CurveTerminator = -10000.0f;

static int CurvePointCount(int maxpoints, const ImVec2* points)
{
    int pointCount = 0;
    while (pointCount < maxpoints && points[pointCount].x > CurveTerminator)
        pointCount++;
    return pointCount;
}

// [src] http://iquilezles.org/www/articles/minispline/minispline.htm
template<int DIM>
void spline(const float* key, int num, float t, float* v)
{
    static const float coefs[16] = {
        -1.0f, 2.0f,-1.0f, 0.0f,
         3.0f,-5.0f, 0.0f, 2.0f,
        -3.0f, 4.0f, 1.0f, 0.0f,
         1.0f,-1.0f, 0.0f, 0.0f
    };

    const int size = DIM + 1;

    int k = 0;
    while (k < num && key[k * size] < t)
        k++;
    if (k <= 0)
        k = 1;
    if (k >= num)
        k = num - 1;

    const float key0 = key[(k - 1) * size];
    const float key1 = key[k * size];

    const float h = (t - key0) / ImMax(key1 - key0, 1e-5f);

    for (int i = 0; i < DIM; i++)
        v[i] = 0.0f;

    for (int i = 0; i < 4; ++i)
    {
        const float* co = &coefs[4 * i];
        const float b = 0.5f * (((co[0] * h + co[1]) * h + co[2]) * h + co[3]);

        const int kn = ImClamp(k + i - 2, 0, num - 1);
        for (int j = 0; j < DIM; j++)
            v[j] += b * key[kn * size + j + 1];
    }
}

float CurveValueSmooth(float p, int maxpoints, const ImVec2* points)
{
    if (maxpoints < 2 || points == nullptr)
        return 0.0f;

    const int pointCount = CurvePointCount(maxpoints, points);
    if (pointCount < 2)
        return 0.0f;

    if (p <= points[0].x)
        return points[0].y;
    if (p >= points[pointCount - 1].x)
        return points[pointCount - 1].y;

    std::vector<float> input(size_t(pointCount) * 2);
    float output[4] = {};

    for (int i = 0; i < pointCount; ++i)
    {
        input[i * 2 + 0] = points[i].x;
        input[i * 2 + 1] = points[i].y;
    }

    spline<1>(input.data(), pointCount, p, output);
    return output[0];
}

float CurveValue(float p, int maxpoints, const ImVec2* points)
{
    if (maxpoints < 2 || points == nullptr)
        return 0.0f;

    const int pointCount = CurvePointCount(maxpoints, points);
    if (pointCount < 2)
        return 0.0f;

    if (p <= points[0].x)
        return points[0].y;
    if (p >= points[pointCount - 1].x)
        return points[pointCount - 1].y;

    int left = 0;
    while (left < pointCount && points[left].x < p)
        left++;
    left = ImClamp(left - 1, 0, pointCount - 2);

    const float dx = points[left + 1].x - points[left].x;
    if (fabsf(dx) <= 1e-5f)
        return points[left].y;

    const float d = (p - points[left].x) / dx;
    return points[left].y + (points[left + 1].y - points[left].y) * d;
}

static inline float ImRemap(float v, float a, float b, float c, float d)
{
    return c + (d - c) * (v - a) / ImMax(b - a, 1e-5f);
}

static inline ImVec2 ImRemap(const ImVec2& v, const ImVec2& a, const ImVec2& b, const ImVec2& c, const ImVec2& d)
{
    return ImVec2(ImRemap(v.x, a.x, b.x, c.x, d.x), ImRemap(v.y, a.y, b.y, c.y, d.y));
}

int Curve(
    const char* label,
    const ImVec2& size,
    const int maxpoints,
    ImVec2* points,
    int* selection,
    const ImVec2& rangeMin,
    const ImVec2& rangeMax
)
{
    int modified = 0;
    if (maxpoints < 2 || points == nullptr)
        return 0;

    if (points[0].x <= CurveTerminator)
    {
        points[0] = rangeMin;
        points[1] = rangeMax;
        if (maxpoints > 2)
            points[2].x = CurveTerminator;
    }

    ImGuiWindow* window = GetCurrentWindow();
    ImGuiContext& g = *GImGui;

    const ImGuiID id = window->GetID(label);
    if (window->SkipItems)
        return 0;

    const ImRect bb(window->DC.CursorPos, window->DC.CursorPos + size);
    ItemSize(bb);
    if (!ItemAdd(bb, id))
        return 0;

    PushID(label);

    int currentSelection = selection ? *selection : -1;
    const bool hovered = ItemHoverable(bb, id, g.LastItemData.ItemFlags);

    int pointCount = CurvePointCount(maxpoints, points);
    pointCount = ImClamp(pointCount, 2, maxpoints);

    const ImGuiStyle& style = g.Style;
    RenderFrame(bb.Min, bb.Max, GetColorU32(ImGuiCol_FrameBg, 1.0f), true, style.FrameRounding);

    const float ht = bb.Max.y - bb.Min.y;
    const float wd = bb.Max.x - bb.Min.x;

    int hoveredPoint = -1;
    const float pointRadiusInPixels = 5.0f;

    if (hovered)
    {
        ImVec2 hoverPos;
        hoverPos.x = (g.IO.MousePos.x - bb.Min.x) / ImMax(bb.Max.x - bb.Min.x, 1e-5f);
        hoverPos.y = (g.IO.MousePos.y - bb.Min.y) / ImMax(bb.Max.y - bb.Min.y, 1e-5f);
        hoverPos.x = ImClamp(hoverPos.x, 0.0f, 1.0f);
        hoverPos.y = 1.0f - ImClamp(hoverPos.y, 0.0f, 1.0f);

        ImVec2 pos = ImRemap(hoverPos, ImVec2(0, 0), ImVec2(1, 1), rangeMin, rangeMax);

        int left = 0;
        while (left < pointCount && points[left].x < pos.x)
            left++;
        left = ImClamp(left - 1, 0, pointCount - 2);

        const ImVec2 hoverPosScreen = ImRemap(hoverPos, ImVec2(0, 0), ImVec2(1, 1), bb.Min, bb.Max);
        const ImVec2 p1s = ImRemap(points[left], rangeMin, rangeMax, bb.Min, bb.Max);
        const ImVec2 p2s = ImRemap(points[left + 1], rangeMin, rangeMax, bb.Min, bb.Max);

        const float p1d = ImSqrt(ImLengthSqr(p1s - hoverPosScreen));
        const float p2d = ImSqrt(ImLengthSqr(p2s - hoverPosScreen));

        if (p1d < pointRadiusInPixels)
            hoveredPoint = left;
        if (p2d < pointRadiusInPixels)
            hoveredPoint = left + 1;

        if (g.IO.MouseDown[0])
        {
            if (currentSelection == -1)
                currentSelection = hoveredPoint;
        }
        else
        {
            currentSelection = -1;
        }

        enum
        {
            action_none,
            action_add_point,
            action_delete_point
        };

        int action = action_none;
        if (currentSelection == -1)
        {
            if (g.IO.MouseDoubleClicked[0] || IsMouseDragging(0))
                action = action_add_point;
        }
        else if (g.IO.MouseDoubleClicked[0])
        {
            action = action_delete_point;
        }

        if (action == action_add_point && pointCount < maxpoints)
        {
            const int insert = left + 1;
            for (int i = pointCount; i > insert; --i)
                points[i] = points[i - 1];

            points[insert] = pos;
            pointCount++;
            if (pointCount < maxpoints)
                points[pointCount].x = CurveTerminator;
            currentSelection = insert;
            modified = 1;
        }
        else if (action == action_delete_point)
        {
            if (currentSelection > 0 && currentSelection < pointCount - 1)
            {
                for (int i = currentSelection; i < pointCount - 1; ++i)
                    points[i] = points[i + 1];
                pointCount--;
                if (pointCount < maxpoints)
                    points[pointCount].x = CurveTerminator;
                currentSelection = -1;
                modified = 1;
            }
        }
    }

    const bool draggingPoint = IsMouseDragging(0) && currentSelection != -1;
    if (draggingPoint)
    {
        if (selection)
            SetActiveID(id, window);
        SetFocusID(id, window);
        FocusWindow(window);

        ImVec2 pos;
        pos.x = (g.IO.MousePos.x - bb.Min.x) / ImMax(bb.Max.x - bb.Min.x, 1e-5f);
        pos.y = (g.IO.MousePos.y - bb.Min.y) / ImMax(bb.Max.y - bb.Min.y, 1e-5f);
        pos.x = ImClamp(pos.x, 0.0f, 1.0f);
        pos.y = 1.0f - ImClamp(pos.y, 0.0f, 1.0f);
        pos = ImRemap(pos, ImVec2(0, 0), ImVec2(1, 1), rangeMin, rangeMax);

        const float pointXRangeMin = (currentSelection > 0) ? points[currentSelection - 1].x : rangeMin.x;
        const float pointXRangeMax = (currentSelection + 1 < pointCount) ? points[currentSelection + 1].x : rangeMax.x;
        pos = ImClamp(pos, ImVec2(pointXRangeMin, rangeMin.y), ImVec2(pointXRangeMax, rangeMax.y));

        points[currentSelection] = pos;

        if (points[0].x <= points[pointCount - 1].x)
        {
            points[0].x = rangeMin.x;
            points[pointCount - 1].x = rangeMax.x;
        }
        else
        {
            points[0].x = rangeMax.x;
            points[pointCount - 1].x = rangeMin.x;
        }

        modified = 1;
    }

    if (!IsMouseDragging(0) && GetActiveID() == id && selection && *selection != -1 && currentSelection == -1)
        ClearActiveID();

    const ImU32 gridColor1 = GetColorU32(ImGuiCol_TextDisabled, 0.5f);
    const ImU32 gridColor2 = GetColorU32(ImGuiCol_TextDisabled, 0.25f);

    ImDrawList* drawList = window->DrawList;
    drawList->AddLine(ImVec2(bb.Min.x, bb.Min.y + ht / 2), ImVec2(bb.Max.x, bb.Min.y + ht / 2), gridColor1, 3.0f);
    drawList->AddLine(ImVec2(bb.Min.x, bb.Min.y + ht / 4), ImVec2(bb.Max.x, bb.Min.y + ht / 4), gridColor1);
    drawList->AddLine(ImVec2(bb.Min.x, bb.Min.y + ht * 3 / 4), ImVec2(bb.Max.x, bb.Min.y + ht * 3 / 4), gridColor1);

    for (int i = 0; i < 9; i++)
    {
        const float x = bb.Min.x + (wd / 10.0f) * float(i + 1);
        drawList->AddLine(ImVec2(x, bb.Min.y), ImVec2(x, bb.Max.y), gridColor2);
    }

    drawList->PushClipRect(bb.Min, bb.Max);

    enum
    {
        smoothness = 256
    };
    for (int i = 0; i <= (smoothness - 1); ++i)
    {
        float px = (i + 0) / float(smoothness);
        float qx = (i + 1) / float(smoothness);

        px = ImRemap(px, 0, 1, rangeMin.x, rangeMax.x);
        qx = ImRemap(qx, 0, 1, rangeMin.x, rangeMax.x);

        const float py = CurveValueSmooth(px, maxpoints, points);
        const float qy = CurveValueSmooth(qx, maxpoints, points);

        ImVec2 p = ImRemap(ImVec2(px, py), rangeMin, rangeMax, ImVec2(0, 0), ImVec2(1, 1));
        ImVec2 q = ImRemap(ImVec2(qx, qy), rangeMin, rangeMax, ImVec2(0, 0), ImVec2(1, 1));
        p.y = 1.0f - p.y;
        q.y = 1.0f - q.y;

        p = ImRemap(p, ImVec2(0, 0), ImVec2(1, 1), bb.Min, bb.Max);
        q = ImRemap(q, ImVec2(0, 0), ImVec2(1, 1), bb.Min, bb.Max);
        drawList->AddLine(p, q, GetColorU32(ImGuiCol_PlotHistogram));
    }

    for (int i = 1; i < pointCount; i++)
    {
        ImVec2 a = ImRemap(points[i - 1], rangeMin, rangeMax, ImVec2(0, 0), ImVec2(1, 1));
        ImVec2 b = ImRemap(points[i], rangeMin, rangeMax, ImVec2(0, 0), ImVec2(1, 1));
        a.y = 1.0f - a.y;
        b.y = 1.0f - b.y;
        a = ImRemap(a, ImVec2(0, 0), ImVec2(1, 1), bb.Min, bb.Max);
        b = ImRemap(b, ImVec2(0, 0), ImVec2(1, 1), bb.Min, bb.Max);
        drawList->AddLine(a, b, GetColorU32(ImGuiCol_PlotLines, 0.5f));
    }

    if (hovered || draggingPoint)
    {
        for (int i = 0; i < pointCount; i++)
        {
            ImVec2 p = ImRemap(points[i], rangeMin, rangeMax, ImVec2(0, 0), ImVec2(1, 1));
            p.y = 1.0f - p.y;
            p = ImRemap(p, ImVec2(0, 0), ImVec2(1, 1), bb.Min, bb.Max);

            if (hoveredPoint == i)
                drawList->AddRect(p - ImVec2(4, 4), p + ImVec2(4, 4), GetColorU32(ImGuiCol_PlotLinesHovered));
            else
                drawList->AddCircle(p, pointRadiusInPixels, GetColorU32(ImGuiCol_PlotLinesHovered));
        }
    }

    drawList->PopClipRect();

    char buf[128];
    const char* str = label;
    if (hovered || draggingPoint)
    {
        ImVec2 pos;
        pos.x = (g.IO.MousePos.x - bb.Min.x) / ImMax(bb.Max.x - bb.Min.x, 1e-5f);
        pos.y = (g.IO.MousePos.y - bb.Min.y) / ImMax(bb.Max.y - bb.Min.y, 1e-5f);
        pos.x = ImClamp(pos.x, 0.0f, 1.0f);
        pos.y = 1.0f - ImClamp(pos.y, 0.0f, 1.0f);
        pos = ImLerp(rangeMin, rangeMax, pos);

        snprintf(buf, sizeof(buf), "%s (%.2f,%.2f)", label, pos.x, pos.y);
        str = buf;
    }
    RenderTextClipped(ImVec2(bb.Min.x, bb.Min.y + style.FramePadding.y), bb.Max, str, nullptr, nullptr, ImVec2(0.5f, 0.5f));

    static const char* items[] = {
        "Custom",

        "Linear",          "Quad in",     "Quad out",   "Quad in  out",  "Cubic in",   "Cubic out",
        "Cubic in  out",   "Quart in",    "Quart out",  "Quart in  out", "Quint in",   "Quint out",
        "Quint in  out",   "Sine in",     "Sine out",   "Sine in  out",  "Expo in",    "Expo out",
        "Expo in  out",    "Circ in",     "Circ out",   "Circ in  out",  "Elastic in", "Elastic out",
        "Elastic in  out", "Back in",     "Back out",   "Back in  out",  "Bounce in",  "Bounce out",
        "Bounce in out",

        "Sine square",     "Exponential",

        "Schubring1",      "Schubring2",  "Schubring3",

        "SinPi2",          "Swing"
    };

    if (BeginPopupContextItem(label))
    {
        if (Selectable("Reset"))
        {
            points[0] = rangeMin;
            points[1] = rangeMax;
            if (maxpoints > 2)
                points[2].x = CurveTerminator;
            modified = 1;
        }
        if (Selectable("Flip"))
        {
            for (int i = 0; i < pointCount; ++i)
            {
                const float yVal = 1.0f - ImRemap(points[i].y, rangeMin.y, rangeMax.y, 0, 1);
                points[i].y = ImRemap(yVal, 0, 1, rangeMin.y, rangeMax.y);
            }
            modified = 1;
        }
        if (Selectable("Mirror"))
        {
            for (int i = 0, j = pointCount - 1; i < j; i++, j--)
                ImSwap(points[i], points[j]);
            for (int i = 0; i < pointCount; ++i)
            {
                const float xVal = 1.0f - ImRemap(points[i].x, rangeMin.x, rangeMax.x, 0, 1);
                points[i].x = ImRemap(xVal, 0, 1, rangeMin.x, rangeMax.x);
            }
            modified = 1;
        }
        Separator();
        if (BeginMenu("Presets"))
        {
            PushID("curve_items");
            for (int row = 0; row < IM_ARRAYSIZE(items); ++row)
            {
                if (MenuItem(items[row]))
                {
                    for (int i = 0; i < maxpoints; ++i)
                    {
                        const float px = i / float(maxpoints - 1);
                        const float py = float(tween::ease(row - 1, px));
                        points[i] = ImRemap(ImVec2(px, py), ImVec2(0, 0), ImVec2(1, 1), rangeMin, rangeMax);
                    }
                    modified = 1;
                }
            }
            PopID();
            EndMenu();
        }

        EndPopup();
    }

    PopID();
    if (selection)
        *selection = currentSelection;
    return modified;
}

} // namespace ImGui

extern "C"
{
IMGUI_API int ImGui_Curve(
    const char* label,
    ImVec2 size,
    int maxpoints,
    ImVec2* points,
    int* selection,
    ImVec2 range_min,
    ImVec2 range_max
)
{
    return ImGui::Curve(label, size, maxpoints, points, selection, range_min, range_max);
}

IMGUI_API float ImGui_CurveValue(float p, int maxpoints, const ImVec2* points)
{
    return ImGui::CurveValue(p, maxpoints, points);
}

IMGUI_API float ImGui_CurveValueSmooth(float p, int maxpoints, const ImVec2* points)
{
    return ImGui::CurveValueSmooth(p, maxpoints, points);
}
}
