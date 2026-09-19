(function () {
  'use strict';

  var COMPATIBILITY_REVISION = '2026.09.19.1';
  var COLOR_MIX_SYNTAX_PROBE = 'color-mix(in oklab, rgb(64, 128, 192) 50%, transparent)';
  var COLOR_MIX_RENDERED_PROBE = 'color-mix(in oklab, var(--clashfx-probe-color) 50%, transparent)';
  var existingDiagnostics = window.__CLASHFX_DASHBOARD_COMPAT__;
  if (existingDiagnostics && existingDiagnostics.revision) return;

  var diagnostics = {
    revision: COMPATIBILITY_REVISION,
    syntaxSupport: false,
    renderedProbe: false,
    expectedProbe: { red: 64, green: 128, blue: 192, alpha: 0.5 },
    observedProbe: null,
    fallbackInstalled: false,
    styleRebuilds: 0,
    themeProbe: {
      startMs: null,
      endMs: null,
      count: 0,
      durationMs: null,
      totalCount: 0,
      batches: 0
    }
  };
  window.__CLASHFX_DASHBOARD_COMPAT__ = diagnostics;

  var themePalette = {
    light: { base: '#fff', primary: '#422ad5', content: '#18181b' },
    dark: { base: '#1d232a', primary: '#605dff', content: '#f2f8ff' },
    cupcake: { base: '#faf7f5', primary: '#44ebd3', content: '#291334' },
    bumblebee: { base: '#fff', primary: '#f7c800', content: '#161616' },
    emerald: { base: '#fff', primary: '#66cc8a', content: '#333c4d' },
    corporate: { base: '#fff', primary: '#0082c4', content: '#181a2a' },
    synthwave: { base: '#09002f', primary: '#f861b4', content: '#a2b2ff' },
    retro: { base: '#ece3ca', primary: '#ff9fa0', content: '#793205' },
    cyberpunk: { base: '#fff25a', primary: '#ff7299', content: '#000' },
    valentine: { base: '#fcf2f8', primary: '#f43098', content: '#c2005b' },
    halloween: { base: '#1b1816', primary: '#ff960c', content: '#cdcdcd' },
    garden: { base: '#e9e7e7', primary: '#f80076', content: '#100f0f' },
    forest: { base: '#1b1717', primary: '#1fb854', content: '#cac9c9' },
    aqua: { base: '#1a368b', primary: '#13ecf3', content: '#b8e6fe' },
    lofi: { base: '#fff', primary: '#0d0d0d', content: '#000' },
    pastel: { base: '#fff', primary: '#e8d4ff', content: '#161616' },
    fantasy: { base: '#fff', primary: '#6b0072', content: '#1f2937' },
    wireframe: { base: '#fff', primary: '#d4d4d4', content: '#161616' },
    black: { base: '#000', primary: '#3a3a3a', content: '#d6d6d6' },
    luxury: { base: '#09090b', primary: '#fff', content: '#dca54d' },
    dracula: { base: '#282a36', primary: '#ff79c6', content: '#f8f8f3' },
    cmyk: { base: '#fff', primary: '#45aeee', content: '#161616' },
    autumn: { base: '#f1f1f1', primary: '#8c0327', content: '#141414' },
    business: { base: '#202020', primary: '#1c4e80', content: '#cdcdcd' },
    acid: { base: '#f8f8f8', primary: '#ff24fb', content: '#000' },
    lemonade: { base: '#f8fdef', primary: '#4b9200', content: '#151614' },
    night: { base: '#0f172a', primary: '#3abdf7', content: '#c9cbd0' },
    coffee: { base: '#261b25', primary: '#db924c', content: '#c59f61' },
    winter: { base: '#fff', primary: '#006ef6', content: '#394e6a' },
    dim: { base: '#2a303c', primary: '#9fe88d', content: '#b2ccd6' },
    nord: { base: '#eceff4', primary: '#5e81ac', content: '#2e3440' },
    sunset: { base: '#121c22', primary: '#ff865b', content: '#9fb9d0' },
    caramellatte: { base: '#fff7ed', primary: '#000', content: '#7c2808' },
    abyss: { base: '#001b20', primary: '#c2fd00', content: '#ffd6a7' },
    silk: { base: '#f7f5f3', primary: '#1c1c29', content: '#4b4743' }
  };

  // MetaCubeXD synchronously asks for three colors for every hidden theme
  // preview. Return its build-time palette without a layout round-trip.
  var nativeGetComputedStyle = window.getComputedStyle.bind(window);
  var themeProbeTimer = null;
  var activeThemeProbeStart = null;
  var activeThemeProbeCount = 0;

  function recordThemeProbe() {
    var now = Date.now();
    if (activeThemeProbeCount === 0) activeThemeProbeStart = now;
    activeThemeProbeCount += 1;

    if (themeProbeTimer) window.clearTimeout(themeProbeTimer);
    themeProbeTimer = window.setTimeout(function () {
      var end = Date.now();
      diagnostics.themeProbe.startMs = activeThemeProbeStart;
      diagnostics.themeProbe.endMs = end;
      diagnostics.themeProbe.count = activeThemeProbeCount;
      diagnostics.themeProbe.durationMs = Math.max(0, end - activeThemeProbeStart);
      diagnostics.themeProbe.totalCount += activeThemeProbeCount;
      diagnostics.themeProbe.batches += 1;
      activeThemeProbeStart = null;
      activeThemeProbeCount = 0;
      themeProbeTimer = null;
    }, 0);
  }

  window.getComputedStyle = function (element, pseudoElement) {
    var themeName = element && element.getAttribute && element.getAttribute('data-theme');
    var palette = themeName && themePalette[themeName];
    var isThemeProbe = palette && !pseudoElement && element.style &&
      element.style.position === 'absolute' && element.style.visibility === 'hidden' &&
      element.style.pointerEvents === 'none';
    if (isThemeProbe) {
      recordThemeProbe();
      return {
        getPropertyValue: function (propertyName) {
          if (propertyName === '--color-base-100') return palette.base;
          if (propertyName === '--color-primary') return palette.primary;
          if (propertyName === '--color-base-content') return palette.content;
          return '';
        }
      };
    }
    return nativeGetComputedStyle(element, pseudoElement);
  };

  diagnostics.syntaxSupport = !!(window.CSS && window.CSS.supports &&
    window.CSS.supports('color', COLOR_MIX_SYNTAX_PROBE));

  function clamp(value, minimum, maximum) {
    return Math.min(maximum, Math.max(minimum, value));
  }

  function component(token, percentageScale) {
    if (!token || typeof token !== 'string') return null;
    var isPercentage = /%$/.test(token);
    var number = Number(token.replace(/%$/, ''));
    if (!isFinite(number)) return null;
    return isPercentage ? number * percentageScale / 100 : number;
  }

  function alphaComponent(token) {
    if (!token) return 1;
    var alpha = component(token, 1);
    return alpha === null ? null : clamp(alpha, 0, 1);
  }

  function colorResult(red, green, blue, alpha, serialization) {
    if (![red, green, blue, alpha].every(isFinite)) return null;
    return {
      red: clamp(red, 0, 255),
      green: clamp(green, 0, 255),
      blue: clamp(blue, 0, 255),
      alpha: clamp(alpha, 0, 1),
      serialization: serialization
    };
  }

  function encodedSRGB(value) {
    var encoded = value <= 0.0031308
      ? 12.92 * value
      : 1.055 * Math.pow(value, 1 / 2.4) - 0.055;
    return clamp(encoded, 0, 1) * 255;
  }

  function labToSRGB(lightness, axisA, axisB, alpha) {
    var fy = (lightness + 16) / 116;
    var fx = fy + axisA / 500;
    var fz = fy - axisB / 200;
    var epsilon = 216 / 24389;
    var kappa = 24389 / 27;
    var inverse = function (value) {
      var cube = value * value * value;
      return cube > epsilon ? cube : (116 * value - 16) / kappa;
    };

    // CSS lab() uses a D50 white point. Adapt it to the D65 white point used by sRGB.
    var x50 = inverse(fx) * 0.96422;
    var y50 = inverse(fy);
    var z50 = inverse(fz) * 0.82521;
    var x65 = 0.9555766 * x50 - 0.0230393 * y50 + 0.0631636 * z50;
    var y65 = -0.0282895 * x50 + 1.0099416 * y50 + 0.0210077 * z50;
    var z65 = 0.0122982 * x50 - 0.0204830 * y50 + 1.3299098 * z50;

    return colorResult(
      encodedSRGB(3.2404542 * x65 - 1.5371385 * y65 - 0.4985314 * z65),
      encodedSRGB(-0.969266 * x65 + 1.8760108 * y65 + 0.041556 * z65),
      encodedSRGB(0.0556434 * x65 - 0.2040259 * y65 + 1.0572252 * z65),
      alpha,
      'lab'
    );
  }

  function oklabToSRGB(lightness, axisA, axisB, alpha) {
    var l = lightness + 0.3963377774 * axisA + 0.2158037573 * axisB;
    var m = lightness - 0.1055613458 * axisA - 0.0638541728 * axisB;
    var s = lightness - 0.0894841775 * axisA - 1.291485548 * axisB;
    l = l * l * l;
    m = m * m * m;
    s = s * s * s;

    return colorResult(
      encodedSRGB(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
      encodedSRGB(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
      encodedSRGB(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
      alpha,
      'oklab'
    );
  }

  function polarToCartesian(chroma, hueDegrees) {
    var hue = hueDegrees * Math.PI / 180;
    return {
      axisA: chroma * Math.cos(hue),
      axisB: chroma * Math.sin(hue)
    };
  }

  function functionalComponents(value, functionName) {
    var expression = new RegExp('^' + functionName + '\\(\\s*(.*?)\\s*\\)$', 'i').exec(value);
    if (!expression) return null;
    var sections = expression[1].split(/\s*\/\s*/);
    var channels = sections[0].indexOf(',') >= 0
      ? sections[0].split(/\s*,\s*/)
      : sections[0].trim().split(/\s+/);
    return { channels: channels, alpha: sections[1] || null };
  }

  function parseRenderedColor(value) {
    if (!value || typeof value !== 'string') return null;
    value = value.trim();
    if (value.toLowerCase() === 'transparent') return colorResult(0, 0, 0, 0, 'transparent');

    var hex = /^#([0-9a-f]{3,8})$/i.exec(value);
    if (hex) {
      var digits = hex[1];
      if (digits.length === 3 || digits.length === 4) {
        digits = digits.split('').map(function (digit) { return digit + digit; }).join('');
      }
      if (digits.length === 6 || digits.length === 8) {
        return colorResult(
          parseInt(digits.slice(0, 2), 16),
          parseInt(digits.slice(2, 4), 16),
          parseInt(digits.slice(4, 6), 16),
          digits.length === 8 ? parseInt(digits.slice(6, 8), 16) / 255 : 1,
          'hex'
        );
      }
    }

    var rgb = functionalComponents(value, 'rgba?');
    if (rgb && (rgb.channels.length === 3 || rgb.channels.length === 4)) {
      var rgbAlpha = alphaComponent(rgb.alpha || rgb.channels[3]);
      var red = component(rgb.channels[0], 255);
      var green = component(rgb.channels[1], 255);
      var blue = component(rgb.channels[2], 255);
      if (red !== null && green !== null && blue !== null && rgbAlpha !== null) {
        return colorResult(red, green, blue, rgbAlpha, 'rgb');
      }
    }

    var srgb = /^color\(\s*srgb\s+(.*?)\s*\)$/i.exec(value);
    if (srgb) {
      var srgbSections = srgb[1].split(/\s*\/\s*/);
      var srgbChannels = srgbSections[0].trim().split(/\s+/);
      var srgbAlpha = alphaComponent(srgbSections[1]);
      if (srgbChannels.length === 3 && srgbAlpha !== null) {
        return colorResult(
          Number(srgbChannels[0]) * 255,
          Number(srgbChannels[1]) * 255,
          Number(srgbChannels[2]) * 255,
          srgbAlpha,
          'color(srgb)'
        );
      }
    }

    var lab = functionalComponents(value, 'lab');
    if (lab && lab.channels.length === 3) {
      var labLightness = component(lab.channels[0], 100);
      var labA = component(lab.channels[1], 125);
      var labB = component(lab.channels[2], 125);
      var labAlpha = alphaComponent(lab.alpha);
      if (labLightness !== null && labA !== null && labB !== null && labAlpha !== null) {
        return labToSRGB(labLightness, labA, labB, labAlpha);
      }
    }

    var oklab = functionalComponents(value, 'oklab');
    if (oklab && oklab.channels.length === 3) {
      var oklabLightness = component(oklab.channels[0], 1);
      var oklabA = component(oklab.channels[1], 0.4);
      var oklabB = component(oklab.channels[2], 0.4);
      var oklabAlpha = alphaComponent(oklab.alpha);
      if (oklabLightness !== null && oklabA !== null && oklabB !== null && oklabAlpha !== null) {
        return oklabToSRGB(oklabLightness, oklabA, oklabB, oklabAlpha);
      }
    }

    var lch = functionalComponents(value, 'lch');
    if (lch && lch.channels.length === 3) {
      var lchLightness = component(lch.channels[0], 100);
      var lchChroma = component(lch.channels[1], 150);
      var lchHue = Number(lch.channels[2].replace(/deg$/i, ''));
      var lchAlpha = alphaComponent(lch.alpha);
      if (lchLightness !== null && lchChroma !== null && isFinite(lchHue) && lchAlpha !== null) {
        var labAxes = polarToCartesian(lchChroma, lchHue);
        return labToSRGB(lchLightness, labAxes.axisA, labAxes.axisB, lchAlpha);
      }
    }

    var oklch = functionalComponents(value, 'oklch');
    if (oklch && oklch.channels.length === 3) {
      var oklchLightness = component(oklch.channels[0], 1);
      var oklchChroma = component(oklch.channels[1], 0.4);
      var oklchHue = Number(oklch.channels[2].replace(/deg$/i, ''));
      var oklchAlpha = alphaComponent(oklch.alpha);
      if (oklchLightness !== null && oklchChroma !== null && isFinite(oklchHue) && oklchAlpha !== null) {
        var oklabAxes = polarToCartesian(oklchChroma, oklchHue);
        return oklabToSRGB(
          oklchLightness,
          oklabAxes.axisA,
          oklabAxes.axisB,
          oklchAlpha
        );
      }
    }
    return null;
  }

  function supportsRenderedColorMix() {
    var root = document.documentElement || document.body;
    if (!root) return false;

    var container = document.createElement('span');
    var probe = document.createElement('span');
    container.setAttribute('aria-hidden', 'true');
    container.style.position = 'absolute';
    container.style.left = '-9999px';
    container.style.visibility = 'hidden';
    container.style.pointerEvents = 'none';
    probe.style.setProperty('--clashfx-probe-color', 'rgb(64, 128, 192)');
    container.appendChild(probe);
    root.appendChild(container);

    var observed = null;
    try {
      // Assign after mounting so WebKit must resolve currentColor in a real tree.
      probe.style.backgroundColor = COLOR_MIX_RENDERED_PROBE;
      observed = parseRenderedColor(nativeGetComputedStyle(probe).backgroundColor || '');
      diagnostics.observedProbe = observed;
    } catch (_) {
      diagnostics.observedProbe = null;
    }
    if (container.parentNode) container.parentNode.removeChild(container);

    if (!observed) return false;
    var expected = diagnostics.expectedProbe;
    return Math.abs(observed.red - expected.red) <= 1 &&
      Math.abs(observed.green - expected.green) <= 1 &&
      Math.abs(observed.blue - expected.blue) <= 1 &&
      Math.abs(observed.alpha - expected.alpha) <= 0.02;
  }

  function installLegacyColorFallbacks() {
    var root = document.documentElement;
    if (!root) return;

    diagnostics.fallbackInstalled = true;

    var styleID = 'clashfx-legacy-color-fallbacks';
    var utilityClasses = {};
    var rebuildScheduled = false;
    var resolvedColors = {};
    var probe = document.createElement('span');
    probe.setAttribute('aria-hidden', 'true');
    probe.style.position = 'absolute';
    probe.style.visibility = 'hidden';
    probe.style.pointerEvents = 'none';
    root.appendChild(probe);

    function activeThemePalette() {
      var themeName = root.getAttribute('data-theme');
      if (!themeName && document.querySelector) {
        var selectedTheme = document.querySelector('input.theme-controller:checked');
        themeName = selectedTheme && selectedTheme.value;
      }
      if (!themeName && window.matchMedia) {
        themeName = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
      }
      return themePalette[themeName] || themePalette.light;
    }

    function safeFallbackColor(variableName) {
      var palette = activeThemePalette();
      var value = palette.content;
      if (/--color-base-(100|200|300)$/.test(variableName)) {
        var base = parseRenderedColor(palette.base);
        var content = parseRenderedColor(palette.content);
        var surfaceLevel = /--color-base-300$/.test(variableName)
          ? 0.16
          : (/--color-base-200$/.test(variableName) ? 0.08 : 0);
        if (base && content && surfaceLevel > 0) {
          return colorResult(
            base.red * (1 - surfaceLevel) + content.red * surfaceLevel,
            base.green * (1 - surfaceLevel) + content.green * surfaceLevel,
            base.blue * (1 - surfaceLevel) + content.blue * surfaceLevel,
            1,
            'safe-surface'
          );
        }
        value = palette.base;
      }
      else if (/--color-primary/.test(variableName)) value = palette.primary;
      else if (/--color-error/.test(variableName)) value = '#ff657f';
      else if (/--color-success/.test(variableName)) value = '#00d193';
      else if (/--color-warning/.test(variableName)) value = '#f9b800';
      else if (/--color-info/.test(variableName)) value = '#00bafc';
      return parseRenderedColor(value) || colorResult(127, 127, 127, 1, 'safe-fallback');
    }

    function readVariableColor(variableName) {
      var rootValue = nativeGetComputedStyle(root).getPropertyValue(variableName) || '';
      var parsedRootValue = parseRenderedColor(rootValue);
      if (parsedRootValue && parsedRootValue.alpha > 0) return parsedRootValue;

      // A legacy WebKit engine can accept var(...) syntactically, yet resolve
      // an unsupported OKLCH value to transparent black. Start with a visible
      // sentinel so invalid assignment cannot be mistaken for a real theme color.
      probe.style.color = 'rgb(1, 2, 3)';
      probe.style.color = 'var(' + variableName + ')';
      var parsedComputedValue = parseRenderedColor(
        nativeGetComputedStyle(probe).color || ''
      );
      if (parsedComputedValue && parsedComputedValue.alpha > 0 && !(
        Math.abs(parsedComputedValue.red - 1) < 0.5 &&
        Math.abs(parsedComputedValue.green - 2) < 0.5 &&
        Math.abs(parsedComputedValue.blue - 3) < 0.5
      )) {
        return parsedComputedValue;
      }
      return safeFallbackColor(variableName);
    }

    function blend(foreground, background, amount) {
      return colorResult(
        foreground.red * amount + background.red * (1 - amount),
        foreground.green * amount + background.green * (1 - amount),
        foreground.blue * amount + background.blue * (1 - amount), 1, 'blend'
      );
    }

    function luminance(color) {
      var linear = function (channel) {
        channel = channel / 255;
        return channel <= 0.04045 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4);
      };
      return 0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue);
    }

    function contrast(first, second) {
      var a = luminance(first);
      var b = luminance(second);
      return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
    }

    function resolvedVariableColor(variableName) {
      if (resolvedColors[variableName]) return resolvedColors[variableName];
      var color = readVariableColor(variableName);
      // Some dark themes deliberately use the same near-black surface for
      // all levels. Without modern translucency those panels disappear.
      if (/^--color-base-(200|300)$/.test(variableName)) {
        var base = resolvedVariableColor('--color-base-100');
        if (luminance(base) < 0.15 && contrast(base, color) < 1.15) {
          color = blend(resolvedVariableColor('--color-base-content'), base,
            variableName === '--color-base-300' ? 0.16 : 0.08);
        }
      }
      resolvedColors[variableName] = color;
      return color;
    }

    function rgb(color) {
      return 'rgb(' + Math.round(color.red) + ', ' + Math.round(color.green) + ', ' + Math.round(color.blue) + ')';
    }

    // Emit an opaque foreground instead of stacking two low alpha values.
    // Test against each standard surface; leave disabled controls' opacity
    // alone. The margin accommodates rounding to 8-bit sRGB.
    function readableColor(variableName, backgrounds, alpha) {
      var desired = resolvedVariableColor(variableName);
      desired = blend(desired, backgrounds[0], alpha * desired.alpha);
      var minimumContrast = function (color) {
        return Math.min.apply(null, backgrounds.map(function (background) { return contrast(color, background); }));
      };
      var white = colorResult(255, 255, 255, 1, 'rgb');
      var black = colorResult(0, 0, 0, 1, 'rgb');
      var target = minimumContrast(white) >= minimumContrast(black) ? white : black;
      for (var step = 0; step <= 20; step++) {
        var candidate = blend(target, desired, step / 20);
        if (minimumContrast(candidate) >= 4.7) return rgb(candidate);
      }
      return rgb(target);
    }

    function buildNavigationRules(surfaces, content) {
      // These are the shipped MobileBottomNav roots (works with both div and
      // nav versions). Inline color-mix backgrounds cannot be fixed by scanning
      // slash-opacity utility classes, so handle the two surfaces explicitly.
      var nav = 'html [class~="fixed"][class~="bottom-0"][class~="lg:hidden"]';
      var popup = 'html [class~="fixed"][class~="bottom-[4.5rem]"][class~="lg:hidden"]';
      var surface = surfaces[2];
      var foreground = readableColor('--color-base-content', [surface], 0.8);
      var primary = resolvedVariableColor('--color-primary');
      var accent = readableColor('--color-primary', [surface, blend(primary, surface, 0.10)], 1);
      return [
        nav + ' > [class~="rounded-2xl"],' + popup + ' > [class~="rounded-2xl"]{background:' + rgb(surface) + '!important;border:1px solid ' + rgbaFor('--color-base-content', 0.24) + '!important}',
        nav + ' a,' + popup + ' a{color:' + foreground + '!important}',
        nav + ' a[class~="text-primary"],' + nav + ' span[class~="text-primary"],' + popup + ' a[class~="text-primary"]{color:' + accent + '!important}',
        nav + ' span[class~="opacity-80"]{opacity:1!important}',
        nav + ' div[class~="bg-primary"],' + popup + ' span[class~="bg-primary"]{background-color:' + accent + '!important}',
        nav + ' button[class~="bg-primary"]{background:' + rgb(primary) + '!important;color:' + readableColor('--color-primary-content', [primary], 1) + '!important}',
        nav + ' button[class~="text-base-content"]{color:' + foreground + '!important}',
        'html,html body{background-color:' + rgb(surfaces[0]) + '!important;color:' + content + '!important}',
        'html [class~="text-base-content"]{color:' + content + '!important}',
        'html [class~="bg-base-100"]{background-color:' + rgb(surfaces[0]) + '!important}',
        'html [class~="bg-base-200"]{background-color:' + rgb(surfaces[1]) + '!important}',
        'html [class~="bg-base-300"]{background-color:' + rgb(surfaces[2]) + '!important}'
      ];
    }

    function rgbaFor(variableName, alpha) {
      var parsed = resolvedVariableColor(variableName);
      return 'rgba(' + Math.round(parsed.red) + ', ' +
        Math.round(parsed.green) + ', ' + Math.round(parsed.blue) + ', ' +
        clamp(alpha * parsed.alpha, 0, 1) + ')';
    }

    function addUtilityClass(className) {
      var match = className.match(/^(bg|text|border|border-r)-([a-z0-9-]+)\/(\d+)(!)?$/i);
      if (!match || match[2] === 'current') return false;
      if (utilityClasses[className]) return false;
      utilityClasses[className] = {
        property: match[1] === 'bg' ? 'background-color' :
          (match[1] === 'text' ? 'color' :
            (match[1] === 'border-r' ? 'border-right-color' : 'border-color')),
        variable: '--color-' + match[2],
        alpha: Math.min(100, Number(match[3])) / 100
      };
      return true;
    }

    function collectUtilityClasses(node) {
      var changed = false;
      if (node.nodeType !== 1) return changed;
      var elements = [node];
      var descendants = node.querySelectorAll ? node.querySelectorAll('[class]') : [];
      for (var i = 0; i < descendants.length; i++) elements.push(descendants[i]);
      for (var elementIndex = 0; elementIndex < elements.length; elementIndex++) {
        var classes = elements[elementIndex].classList;
        if (!classes) continue;
        for (var classIndex = 0; classIndex < classes.length; classIndex++) {
          if (addUtilityClass(classes.item(classIndex))) changed = true;
        }
      }
      return changed;
    }

    function buildConnectionRules(readableContent) {
      var content = function (alpha) { return rgbaFor('--color-base-content', alpha); };
      var primary = function (alpha) { return rgbaFor('--color-primary', alpha); };
      var error = function (alpha) { return rgbaFor('--color-error', alpha); };
      return [
        '.conn-table-container{--conn-border:' + content(0.10) + '!important}',
        '.conn-th{color:' + readableContent + '!important}',
        '.conn-group-btn,.conn-group-count,.conn-card-group-count,.conn-empty,.conn-td-label{color:' + readableContent + '!important}',
        '.conn-group-btn:hover,.conn-copy-btn:hover{background:' + primary(0.10) + '!important}',
        '.conn-group-row,.conn-card-group{background:' + primary(0.05) + '!important}',
        '.conn-group-row:hover,.conn-card-group:hover{background:' + primary(0.10) + '!important}',
        '.conn-group-icon,.conn-card-group-icon{background:' + primary(0.15) + '!important}',
        '.conn-data-row:nth-child(2n){background:' + content(0.02) + '!important}',
        '.conn-data-row:hover{background:' + content(0.05) + '!important}',
        '.conn-td{border-bottom-color:' + content(0.05) + '!important}',
        '.conn-card{border-color:' + content(0.08) + '!important}',
        '.conn-card:hover{border-color:' + content(0.15) + '!important}',
        '.conn-card__process{color:' + readableContent + '!important}',
        '.conn-card__aux,.conn-aux{color:' + readableContent + '!important}',
        '.conn-copy-btn{color:' + readableContent + '!important}',
        '.conn-close-btn{background:' + error(0.10) + '!important}',
        '.conn-close-btn:hover{background:' + error(0.20) + '!important}'
      ];
    }

    function rebuildStyles() {
      rebuildScheduled = false;
      resolvedColors = {};
      diagnostics.styleRebuilds += 1;
      var existingStyle = document.getElementById(styleID);
      if (existingStyle) existingStyle.remove();
      var style = document.createElement('style');
      style.id = styleID;
      var surfaces = ['--color-base-100', '--color-base-200', '--color-base-300'].map(resolvedVariableColor);
      var readableContent = readableColor('--color-base-content', surfaces, 0.8);
      var rules = buildConnectionRules(readableContent);
      Object.keys(utilityClasses).forEach(function (className) {
        var descriptor = utilityClasses[className];
        var escapedName = className.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
        var value = descriptor.property === 'color' && descriptor.variable === '--color-base-content' && descriptor.alpha > 0
          ? readableColor(descriptor.variable, surfaces, descriptor.alpha)
          : rgbaFor(descriptor.variable, descriptor.alpha);
        rules.push('html [class~="' + escapedName + '"]{' + descriptor.property + ':' + value + '!important}');
      });
      rules = rules.concat(buildNavigationRules(surfaces, readableColor('--color-base-content', surfaces, 1)));
      style.textContent = rules.join('\n');
      (document.head || root).appendChild(style);
    }

    function scheduleRebuild() {
      if (rebuildScheduled) return;
      rebuildScheduled = true;
      window.requestAnimationFrame(rebuildStyles);
    }

    collectUtilityClasses(root);
    rebuildStyles();

    new MutationObserver(function (mutations) {
      var changed = false;
      for (var i = 0; i < mutations.length; i++) {
        if (mutations[i].type === 'attributes') {
          // Only inspect this element for class changes; rescanning a whole
          // subtree for each reactive update makes the theme picker sluggish.
          var classes = mutations[i].target.classList;
          for (var k = 0; classes && k < classes.length; k++) {
            if (addUtilityClass(classes.item(k))) changed = true;
          }
        }
        for (var j = 0; j < mutations[i].addedNodes.length; j++) {
          if (collectUtilityClasses(mutations[i].addedNodes[j])) changed = true;
        }
      }
      if (changed) scheduleRebuild();
    }).observe(root, { childList: true, subtree: true, attributes: true, attributeFilter: ['class'] });

    new MutationObserver(scheduleRebuild).observe(root, {
      attributes: true,
      attributeFilter: ['data-theme']
    });
  }

  function activateCompatibility() {
    diagnostics.renderedProbe = supportsRenderedColorMix();
    if (!diagnostics.renderedProbe) installLegacyColorFallbacks();
  }

  if (window.__CLASHFX_DASHBOARD_COMPAT_TESTING__) {
    diagnostics.testing = {
      parseRenderedColor: parseRenderedColor,
      renderedProbeExpression: COLOR_MIX_RENDERED_PROBE
    };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', activateCompatibility);
  } else {
    activateCompatibility();
  }
})();
