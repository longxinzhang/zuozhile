const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./deveco-sdk.cjs').typescript;

const root = path.resolve(__dirname, '..');
const file = path.join(root, 'entry/src/main/ets/components/LowScoreEdgeLight.ets');
const text = fs.readFileSync(file, 'utf8');
const parseOptions = {
  ets: {
    render: { method: ['build'], decorator: ['Builder'] },
    components: ['Canvas', 'Stack', 'Column', 'Row', 'Rect', 'Text', 'Image'],
    libs: [],
    extend: { decorator: [], components: [] },
    styles: {
      decorator: 'Styles',
      component: { name: 'Common', type: 'CommonAttribute', instance: 'CommonInstance' },
      property: '__style__'
    },
    concurrent: { decorator: 'Concurrent' },
    propertyDecorators: [],
    emitDecorators: [],
    syntaxComponents: { paramsUICallback: [], attrUICallback: [] }
  }
};
const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, parseOptions);
const component = source.statements.find(node => ts.isStructDeclaration(node) &&
  node.name.text === 'LowScoreEdgeLight');
assert.ok(component, 'LowScoreEdgeLight struct must exist');
const hasDecorator = (node, name) => (ts.getDecorators(node) || []).some(decorator =>
  ts.isIdentifier(decorator.expression) && decorator.expression.text === name);
const decoratorValue = (node, name) => (ts.getDecorators(node) || []).find(decorator =>
  ts.isCallExpression(decorator.expression) && ts.isIdentifier(decorator.expression.expression) &&
  decorator.expression.expression.text === name)?.expression.arguments[0]?.text;
const build = component.members.find(member => member.name?.getText(source) === 'build');
assert.ok(build, 'LowScoreEdgeLight build must exist');
const uiNodes = [];
const visitUI = node => {
  if (ts.isEtsComponentExpression(node)) uiNodes.push(node);
  ts.forEachChild(node, visitUI);
};
visitUI(component);
assert.equal(uiNodes.length, 1, 'The screen effect must have exactly one UI node');
const canvas = uiNodes[0];
assert.equal(canvas.expression.getText(source), 'Canvas');
const canvasAttrs = modifiers(canvas);
const members = component.members.filter(member => member.name &&
  (ts.isPropertyDeclaration(member) || ts.isMethodDeclaration(member) &&
    member.name.getText(source) !== 'build' && !hasDecorator(member, 'Builder')))
  .map(member => ts.isPropertyDeclaration(member) ? ts.factory.updatePropertyDeclaration(member,
    ts.getModifiers(member), member.name, member.questionToken || member.exclamationToken,
    member.type, member.initializer) : member);
const levelFile = path.join(root, 'entry/src/main/ets/models/LowScoreReminder.ets');
const levelSource = ts.createSourceFile(levelFile, fs.readFileSync(levelFile, 'utf8'),
  ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, parseOptions);
const levelEnum = levelSource.statements.find(node => ts.isEnumDeclaration(node) &&
  node.name.text === 'LowScoreLevel');
assert.ok(levelEnum, 'Use the actual LowScoreLevel enum');
const printer = ts.createPrinter({ removeComments: true });
const geometryFile = path.join(root, 'entry/src/main/ets/models/EdgeLightGeometry.ets');
const geometrySource = ts.createSourceFile(geometryFile, fs.readFileSync(geometryFile, 'utf8'),
  ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, parseOptions);
const geometryRuntime = ts.transpileModule(printer.printFile(geometrySource), {
  fileName: 'edge-geometry.ts',
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
  reportDiagnostics: true
});
const geometryModule = { exports: {} };
new vm.Script(geometryRuntime.outputText, { filename: geometryFile }).runInNewContext({
  module: geometryModule, exports: geometryModule.exports
});
const { edgeGlowWedges, edgeGlowStops } = geometryModule.exports;
const lightColor = 'app.color.low_score_edge_light';
const strongColor = 'app.color.low_score_edge_strong';
const palettes = [
  { [lightColor]: { red: 211, green: 137, blue: 129 }, [strongColor]: { red: 239, green: 123, blue: 113 } },
  { [lightColor]: { red: 229, green: 149, blue: 141 }, [strongColor]: { red: 213, green: 81, blue: 73 } }
];
let mockColorMode = 1;
let scopedCalls = 0;
let inUIScope = false;
let canvasDraws = 0;
let partitionProbes = 0;
const ColorMetrics = {
  resourceColor(resource) {
    assert.equal(inUIScope, true, 'Resource colors must be resolved inside the owning UIContext scope');
    const rgb = palettes[mockColorMode][resource];
    assert.ok(rgb, 'Only the light/strong edge resource may be resolved');
    return { ...rgb, color: { ...rgb, alpha: 1, resource } };
  },
  rgba(red, green, blue, alpha = 1) {
    assert.ok([red, green, blue, alpha].every(Number.isFinite), `Invalid RGBA: ${[red, green, blue, alpha]}`);
    assert.ok(alpha >= 0 && alpha <= 1);
    return { red, green, blue, color: { red, green, blue, alpha } };
  }
};
class RenderingContextSettings {
  constructor(antialias) { this.antialias = antialias; }
}
class CanvasRenderingContext2D {
  constructor(settings) {
    this.settings = settings;
    this.width = 0;
    this.height = 0;
    this.operations = [];
    this.frame = { clear: undefined, gradients: [], fills: [], strokes: [] };
    this.path = [];
  }
  set lineWidth(value) {
    assert.ok(Number.isFinite(value) && value > 0);
    this.appliedLineWidth = value;
  }
  get lineWidth() { return undefined; }
  clearRect(...rect) {
    canvasDraws++;
    this.operations.push('clearRect');
    this.frame = { clear: rect, gradients: [], fills: [], strokes: [] };
  }
  createLinearGradient(...axes) {
    const gradient = { axes, stops: [], addColorStop(offset, color) {
      this.stops.push({ offset, color: { ...color } });
    } };
    this.frame.gradients.push(gradient);
    this.operations.push('createLinearGradient');
    return gradient;
  }
  beginPath() { this.path = []; this.closed = false; this.operations.push('beginPath'); }
  moveTo(x, y) { assert.equal(this.path.length, 0); this.path.push([x, y]); this.operations.push('moveTo'); }
  lineTo(x, y) { this.path.push([x, y]); this.operations.push('lineTo'); }
  closePath() { this.closed = true; this.operations.push('closePath'); }
  fill() {
    assert.ok(this.frame.gradients.includes(this.fillStyle), 'No solid red-band fill is allowed');
    this.frame.fills.push({ points: this.path.map(point => [...point]), closed: this.closed,
      gradient: this.fillStyle });
    this.operations.push('fill');
  }
  strokeRect(...rect) {
    assert.ok(rect.every(Number.isFinite), 'Canvas setter-only properties cannot be read back for geometry');
    this.frame.strokes.push({ rect, color: { ...this.strokeStyle }, lineWidth: this.appliedLineWidth });
    this.operations.push('strokeRect');
  }
  fillRect() { assert.fail('No red-band rectangle fill is allowed'); }
  rect() { assert.fail('Only wedge paths may be filled'); }
  stroke() { assert.fail('Only the reduceMotion strokeRect is allowed'); }
}
const declaration = ts.factory.createClassDeclaration(undefined, 'EdgeHarness', undefined, undefined, members);
const runtime = ts.transpileModule([
  printer.printNode(ts.EmitHint.Unspecified,
    ts.factory.updateEnumDeclaration(levelEnum, undefined, levelEnum.name, levelEnum.members), levelSource),
  printer.printNode(ts.EmitHint.Unspecified, declaration, source),
  `function canvasHooks() { return {
    ready: ${printer.printNode(ts.EmitHint.Expression, canvasAttrs.get('onReady')[0], source)},
    area: ${printer.printNode(ts.EmitHint.Expression, canvasAttrs.get('onAreaChange')[0], source)}
  }; }`,
  '({ Edge: EdgeHarness, Level: LowScoreLevel, canvasHooks });'
].join('\n'), {
  fileName: 'edge-harness.ts',
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
  reportDiagnostics: true
});
const { Edge, Level, canvasHooks } = new vm.Script(runtime.outputText, { filename: file }).runInNewContext({
  ...geometryModule.exports, ColorMetrics, RenderingContextSettings, CanvasRenderingContext2D,
  $r: resource => resource
});
const levels = [Level.LIGHT, Level.MEDIUM, Level.SEVERE];
const colorFor = level => level === Level.LIGHT ? lightColor : strongColor;
let checks = 0;

function check(name, run) {
  run();
  checks++;
  console.log('PASS: ' + name);
}

function near(actual, expected) {
  assert.ok(Math.abs(actual - expected) < 1e-9, `${actual} != ${expected}`);
}

function evaluate(node, edge) {
  if (node.kind === ts.SyntaxKind.ThisKeyword) return edge;
  if (node.kind === ts.SyntaxKind.TrueKeyword) return true;
  if (node.kind === ts.SyntaxKind.FalseKeyword) return false;
  if (ts.isIdentifier(node) && node.text === 'LowScoreLevel') return Level;
  if (ts.isNumericLiteral(node)) return Number(node.text);
  if (ts.isParenthesizedExpression(node)) return evaluate(node.expression, edge);
  if (ts.isConditionalExpression(node)) return evaluate(node.condition, edge) ?
    evaluate(node.whenTrue, edge) : evaluate(node.whenFalse, edge);
  if (ts.isPropertyAccessExpression(node)) return evaluate(node.expression, edge)[node.name.text];
  if (ts.isBinaryExpression(node)) {
    const left = evaluate(node.left, edge);
    switch (node.operatorToken.kind) {
      case ts.SyntaxKind.AmpersandAmpersandToken: return left && evaluate(node.right, edge);
      case ts.SyntaxKind.BarBarToken: return left || evaluate(node.right, edge);
      case ts.SyntaxKind.EqualsEqualsEqualsToken: return left === evaluate(node.right, edge);
      case ts.SyntaxKind.GreaterThanEqualsToken: return left >= evaluate(node.right, edge);
      case ts.SyntaxKind.GreaterThanToken: return left > evaluate(node.right, edge);
    }
  }
  assert.fail('Unsupported render condition: ' + node.getText(source));
}

function modifiers(node) {
  const values = new Map();
  while (ts.isPropertyAccessExpression(node.parent) && node.parent.expression === node &&
    ts.isCallExpression(node.parent.parent) && node.parent.parent.expression === node.parent) {
    const call = node.parent.parent;
    values.set(node.parent.name.text, call.arguments);
    node = call;
  }
  return values;
}

function fixture(level = Level.NORMAL, props = {}, appear = true, autoReady = true) {
  const edge = new Edge();
  const hooks = canvasHooks.call(edge);
  const animators = [];
  const samples = [];
  const conversions = [];
  for (const name of ['renderedLevel', 'colorMode', 'windowWidthPx', 'windowHeightPx']) {
    let value = edge[name];
    const watch = decoratorValue(component.members.find(member => member.name?.getText(source) === name), 'Watch');
    assert.equal(watch, name.startsWith('window') ? 'resizeDrawing' : 'draw');
    Object.defineProperty(edge, name, { get: () => value, set: next => {
      if (next === value) return;
      value = next;
      edge[watch]();
    } });
  }
  const snapshot = () => {
    const opacity = evaluate(canvasAttrs.get('opacity')[0], edge);
    near(opacity, edge.active && edge.effectEnabled ? edge.edgeAlpha : 0);
    const frame = edge.context.frame;
    const colors = frame.fills.flatMap(fill => fill.gradient.stops.map(stop => stop.color))
      .concat(frame.strokes.map(stroke => stroke.color));
    const painted = [...new Set(colors.map(color => Object.keys(palettes[mockColorMode]).find(name => {
      const rgb = palettes[mockColorMode][name];
      return color.red === rgb.red && color.green === rgb.green && color.blue === rgb.blue;
    })))];
    assert.ok(!painted.includes(undefined), 'Every stop uses the resolved shade, including alpha zero');
    assert.ok(painted.length <= 1, 'Never paint two edge shades');
    const layers = edge.canvasReady && opacity > 0 ? painted : [];
    assert.ok([Level.NORMAL, ...levels].includes(edge.renderedLevel), 'Rendered level must be a single enum value');
    assert.ok(Number.isFinite(edge.edgeAlpha) && edge.edgeAlpha >= 0 && edge.edgeAlpha <= 1);
    const visible = edge.attached && edge.canvasReady && edge.active && edge.effectEnabled &&
      edge.edgeAlpha > 0 && edge.renderedLevel !== Level.NORMAL;
    assert.deepEqual(layers, visible ? [colorFor(edge.renderedLevel)] : []);
    if (edge.attached && edge.canvasReady) {
      assert.deepEqual(frame.clear, [0, 0, edge.context.width, edge.context.height]);
      assert.ok(frame.fills.length === 0 || frame.fills.length === 4);
      assert.equal(frame.gradients.length, frame.fills.length);
      assert.ok(frame.strokes.length <= 1);
      if (frame.fills.length) assert.equal(frame.strokes.length, 0, 'Never combine glow and a hard border');
    }
    const running = animators.filter(animator => animator.running);
    assert.ok(running.length <= 1, 'At most one animator may be running');
    if (running.length) assert.equal(edge.effectAnimator, running[0]);
    const state = {
      alpha: edge.edgeAlpha, renderedLevel: edge.renderedLevel, level: edge.level,
      active: edge.active, effectEnabled: edge.effectEnabled, reduceMotion: edge.reduceMotion,
      attached: edge.attached, generation: edge.generation, animator: edge.effectAnimator,
      created: animators.length, layers, opacity, canvasReady: edge.canvasReady,
      drawingWidth: edge.drawingWidth, drawingHeight: edge.drawingHeight,
      canvasSize: [edge.context.width, edge.context.height], operations: edge.context.operations.length,
      paint: {
        clear: frame.clear?.slice(),
        fills: frame.fills.map(fill => ({ points: fill.points.map(point => [...point]), closed: fill.closed,
          axes: [...fill.gradient.axes], stops: fill.gradient.stops.map(stop => [stop.offset,
            stop.color.red, stop.color.green, stop.color.blue, stop.color.alpha]) })),
        strokes: frame.strokes.map(stroke => ({ rect: [...stroke.rect], color: { ...stroke.color },
          lineWidth: stroke.lineWidth }))
      },
      controls: animators.map(animator => [animator.playCalls, animator.cancelCalls, animator.running])
    };
    samples.push(state);
    return state;
  };
  const uiContext = {
    runScopedTask(callback) {
      scopedCalls++;
      const previous = inUIScope;
      inUIScope = true;
      try { callback(); } finally { inUIScope = previous; }
    },
    px2vp(pixels) { conversions.push(pixels); return pixels / 3; },
    createAnimator(options) {
      const animator = {
        options: { ...options }, onFrame: undefined, onFinish: undefined, captured: undefined,
        running: false, playCalls: 0, cancelCalls: 0,
        play() {
          this.captured = { frame: this.onFrame, finish: this.onFinish };
          assert.equal(typeof this.onFrame, 'function');
          this.running = true;
          this.playCalls++;
          snapshot();
          this.frame(this.options.begin);
        },
        cancel() {
          this.running = false;
          this.cancelCalls++;
          this.onFrame?.(this.options.end);
          snapshot();
        },
        frame(value) {
          this.onFrame(value);
          return snapshot();
        },
        finish() {
          assert.equal(this.options.iterations, 1, 'Only finite fades finish in the harness');
          this.running = false;
          this.frame(this.options.end);
          assert.equal(typeof this.onFinish, 'function');
          this.onFinish();
          return snapshot();
        }
      };
      animators.push(animator);
      return animator;
    }
  };
  edge.getUIContext = () => uiContext;
  Object.assign(edge, { level, windowWidthPx: 1320, windowHeightPx: 2760 }, props);
  const layout = () => {
    edge.context.width = typeof edge.drawingWidth === 'number' ? edge.drawingWidth : 440;
    edge.context.height = typeof edge.drawingHeight === 'number' ? edge.drawingHeight : 920;
  };
  const ready = () => { layout(); hooks.ready(); return snapshot(); };
  const area = () => { layout(); hooks.area(); return snapshot(); };
  const resize = (width, height) => {
    Object.assign(edge, { windowWidthPx: width, windowHeightPx: height });
    return area();
  };
  const current = () => {
    assert.ok(edge.effectAnimator, 'An animator must be active');
    return edge.effectAnimator;
  };
  const change = values => {
    Object.assign(edge, values);
    edge.refreshEffect();
    return snapshot();
  };
  snapshot();
  if (appear) edge.aboutToAppear();
  if (appear && autoReady) ready();
  snapshot();
  return { edge, animators, samples, conversions, snapshot, current, change, ready, area, resize,
    finish: () => current().finish() };
}

function cross(a, b, point) {
  return (b[0] - a[0]) * (point[1] - a[1]) - (b[1] - a[1]) * (point[0] - a[0]);
}

function polygonArea(points) {
  return Math.abs(points.reduce((sum, point, index) => {
    const next = points[(index + 1) % points.length];
    return sum + point[0] * next[1] - next[0] * point[1];
  }, 0)) / 2;
}

function intersectionArea(first, second) {
  let points = first;
  for (let index = 0; index < second.length && points.length; index++) {
    const a = second[index], b = second[(index + 1) % second.length];
    const clipped = [];
    for (let cursor = 0; cursor < points.length; cursor++) {
      const previous = points[(cursor + points.length - 1) % points.length], current = points[cursor];
      const before = cross(a, b, previous), after = cross(a, b, current);
      if ((before >= 0) !== (after >= 0)) {
        const ratio = before / (before - after);
        clipped.push([previous[0] + (current[0] - previous[0]) * ratio,
          previous[1] + (current[1] - previous[1]) * ratio]);
      }
      if (after >= 0) clipped.push(current);
    }
    points = clipped;
  }
  return polygonArea(points);
}

function verifyWedges(wedges, width, height) {
  assert.equal(wedges.length, 4);
  const center = [width / 2, height / 2];
  const corners = [[0, 0], [width, 0], [width, height], [0, height]];
  const starts = [[width / 2, 0], [width, height / 2], [width / 2, height], [0, height / 2]];
  const triangles = Array.from(wedges, (wedge, index) => {
    assert.deepEqual(wedge.start, starts[index], 'Gradient begins at the physical screen edge');
    assert.deepEqual(wedge.end, center, 'Gradient ends at the screen center');
    assert.deepEqual(wedge.points, [corners[index], corners[(index + 1) % 4], center]);
    assert.ok(wedge.points.flat().every(Number.isFinite));
    const points = wedge.points.map(point => [point[0] / width, point[1] / height]);
    near(polygonArea(points), 0.25);
    assert.ok(cross(points[0], points[1], points[2]) > 0);
    return points;
  });
  near(triangles.reduce((sum, points) => sum + polygonArea(points), 0), 1);
  for (let first = 0; first < triangles.length; first++) {
    for (let second = first + 1; second < triangles.length; second++) {
      near(intersectionArea(triangles[first], triangles[second]), 0);
    }
  }
  for (const x of [0.013, 0.13, 0.37, 0.49, 0.67, 0.87, 0.997]) {
    for (const y of [0.019, 0.11, 0.29, 0.53, 0.71, 0.89, 0.991]) {
      assert.equal(triangles.filter(points => points.every((point, index) =>
        cross(point, points[(index + 1) % points.length], [x, y]) > 0)).length, 1,
      'Every interior probe belongs to exactly one wedge');
      partitionProbes++;
    }
  }
}

function gradientAlpha(gradient, point) {
  const [x, y, endX, endY] = gradient.axes;
  const dx = endX - x, dy = endY - y;
  const offset = Math.max(0, Math.min(1, ((point[0] - x) * dx + (point[1] - y) * dy) / (dx * dx + dy * dy)));
  for (let index = 1; index < gradient.stops.length; index++) {
    const previous = gradient.stops[index - 1], next = gradient.stops[index];
    if (offset <= next.offset) return previous.color.alpha +
      (next.color.alpha - previous.color.alpha) * (offset - previous.offset) / (next.offset - previous.offset);
  }
  assert.fail('Every gradient must reach offset 1');
}

function verifyDrawing(test) {
  const { edge } = test;
  const { width, height, frame } = edge.context;
  assert.deepEqual(frame.clear, [0, 0, width, height]);
  const strong = edge.renderedLevel >= Level.MEDIUM;
  const rgb = palettes[mockColorMode][colorFor(edge.renderedLevel)];
  if (edge.reduceMotion) {
    assert.equal(frame.fills.length, 0);
    assert.equal(frame.gradients.length, 0);
    assert.equal(frame.strokes.length, 1);
    const stroke = frame.strokes[0], lineWidth = strong ? 2 : 1.5;
    assert.equal(stroke.lineWidth, lineWidth);
    assert.deepEqual(stroke.rect, [lineWidth / 2, lineWidth / 2, width - lineWidth, height - lineWidth]);
    assert.deepEqual(stroke.color, { ...rgb, alpha: 1, resource: colorFor(edge.renderedLevel) });
    return;
  }
  assert.equal(frame.gradients.length, 4);
  assert.equal(frame.fills.length, 4);
  assert.equal(frame.strokes.length, 0);
  verifyWedges(frame.fills.map(fill => ({ start: fill.gradient.axes.slice(0, 2),
    end: fill.gradient.axes.slice(2), points: fill.points })), width, height);
  for (const fill of frame.fills) {
    assert.equal(fill.closed, true);
    const gradient = fill.gradient;
    const stops = Array.from(edgeGlowStops(strong));
    assert.equal(gradient.stops.length, stops.length);
    for (let index = 0; index < stops.length; index++) {
      assert.equal(gradient.stops[index].offset, stops[index].offset);
      assert.deepEqual(gradient.stops[index].color, { ...rgb, alpha: stops[index].alpha });
    }
    const [x, y, endX, endY] = gradient.axes;
    let previous = Infinity;
    for (let index = 0; index <= 100; index++) {
      const point = [x + (endX - x) * index / 100, y + (endY - y) * index / 100];
      const alpha = gradientAlpha(gradient, point);
      assert.ok(alpha < previous, 'Alpha must continuously decrease inward without a hard red band');
      previous = alpha;
    }
    near(gradientAlpha(gradient, [width / 2, height / 2]), 0);
    for (const point of fill.points.slice(0, 2)) near(gradientAlpha(gradient, point), strong ? 0.76 : 0.58);
  }
}

function replayStale(test, animators) {
  const before = test.snapshot();
  for (const animator of animators) {
    animator.captured.frame(animator.options.end);
    assert.deepEqual(test.snapshot(), before, 'Stale onFrame must not change state or animator');
    animator.captured.finish?.();
    assert.deepEqual(test.snapshot(), before, 'Stale onFinish must not change state or animator');
  }
}

function inPhase(phase, level = Level.LIGHT) {
  const test = fixture(level);
  if (phase === 'entry') {
    test.current().frame(0.5);
    return test;
  }
  test.finish();
  test.current().frame(test.current().options.end);
  if (phase === 'breathing') return test;
  test.change({ level: phase === 'recovery' ? Level.NORMAL : level === Level.LIGHT ? Level.MEDIUM : Level.LIGHT });
  if (phase === 'switch-in') test.finish();
  test.current().frame(0.5);
  return test;
}

const phases = ['entry', 'breathing', 'switch-out', 'switch-in', 'recovery'];

check('SDK parses actual ArkTS component/geometry and extracts runtime methods and Canvas callbacks without UI', () => {
  assert.equal(source.parseDiagnostics.length, 0);
  assert.equal(levelSource.parseDiagnostics.length, 0);
  assert.equal(geometrySource.parseDiagnostics.length, 0);
  assert.equal(geometryRuntime.diagnostics.length, 0);
  assert.equal(runtime.diagnostics.length, 0);
  assert.deepEqual(component.members.filter(member => member.name && hasDecorator(member, 'State'))
    .map(member => member.name.getText(source)), ['drawingWidth', 'drawingHeight', 'edgeAlpha', 'renderedLevel']);
  for (const [name, storage, watch] of [['colorMode', 'appColorMode', 'draw'],
    ['windowWidthPx', 'glowWindowWidthPx', 'resizeDrawing'],
    ['windowHeightPx', 'glowWindowHeightPx', 'resizeDrawing']]) {
    const field = component.members.find(member => member.name?.getText(source) === name);
    assert.equal(decoratorValue(field, 'StorageProp'), storage);
    assert.equal(decoratorValue(field, 'Watch'), watch);
  }
  for (const name of ['aboutToAppear', 'aboutToDisappear', 'refreshEffect', 'cancelEffect', 'fadeAlpha',
    'startBreathing', 'draw', 'resizeDrawing']) {
    assert.equal(typeof Edge.prototype[name], 'function');
  }
  assert.equal(Edge.prototype.build, undefined);
});

check('one window-sized Canvas binds alpha and ignores touch/accessibility inside the full-screen host', () => {
  assert.equal(canvas.arguments[0].getText(source), 'this.context');
  assert.equal(canvasAttrs.get('width')?.[0].getText(source), 'this.drawingWidth');
  assert.equal(canvasAttrs.get('height')?.[0].getText(source), 'this.drawingHeight');
  assert.equal(canvasAttrs.get('align')?.[0].getText(source), 'Alignment.TopStart');
  assert.equal(canvasAttrs.get('hitTestBehavior')?.[0].getText(source), 'HitTestMode.None');
  assert.equal(canvasAttrs.get('accessibilityLevel')?.[0].text, 'no');
  assert.equal(canvasAttrs.get('backgroundColor')?.[0].getText(source), 'Color.Transparent');
  assert.equal(canvasAttrs.get('id')?.[0].text, 'low-score-screen-glow');
  assert.equal(canvasAttrs.has('ignoreLayoutSafeArea'), false,
    'The host owns layout expansion; the Canvas must not apply the safe-area transform twice');
  assert.equal(canvasAttrs.has('expandSafeArea'), false,
    'The window-sized Canvas must not rely on drawing-only safe-area expansion');
  assert.ok(ts.isArrowFunction(canvasAttrs.get('onReady')[0]));
  assert.ok(ts.isArrowFunction(canvasAttrs.get('onAreaChange')[0]));
  for (const attr of ['border', 'borderRadius', 'linearGradient', 'padding', 'margin', 'shadow', 'clip']) {
    assert.equal(canvasAttrs.has(attr), false, 'No card, safe-area inset or hard border: ' + attr);
  }
});

check('animated drawing uses wedge gradients only; strokeRect is restricted to reduceMotion and no sampling/timers', () => {
  const draw = component.members.find(member => member.name?.getText(source) === 'draw');
  const calls = [];
  const visit = node => {
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression)) calls.push(node);
    ts.forEachChild(node, visit);
  };
  visit(draw.body);
  const strokes = calls.filter(node => node.expression.name.text === 'strokeRect');
  assert.equal(strokes.length, 1);
  let branch = strokes[0].parent;
  while (branch && !ts.isIfStatement(branch)) branch = branch.parent;
  assert.equal(branch?.expression.getText(source), 'this.reduceMotion');
  assert.ok(branch.thenStatement.statements.some(ts.isReturnStatement));
  assert.equal(calls.filter(node => node.expression.name.text === 'fill').length, 1);
  assert.equal(calls.filter(node => node.expression.name.text === 'createLinearGradient').length, 1);
  assert.ok(calls.some(node => node.expression.getText(source) === 'ColorMetrics.resourceColor'));
  assert.ok(calls.some(node => node.expression.getText(source) === 'ColorMetrics.rgba'));
  assert.deepEqual(source.statements.filter(ts.isImportDeclaration).map(node => node.moduleSpecifier.text),
    ['@kit.ArkUI', '../models/LowScoreReminder', '../models/EdgeLightGeometry']);
  assert.doesNotMatch(text, /\b(?:camera\w*|sampling\w*|PostureSample|requestFrame|capture\w*|timer|setInterval|setTimeout|clearInterval|clearTimeout|requestAnimationFrame|window|setWindowBrightness|audio|sound\w*|vibrator)\b/i);
  assert.doesNotMatch(text, /\.(?:shadow|border|fillRect|rect|stroke|backgroundImage)\s*\(|\b(?:Text|Rect|Image)\s*\(/);
});

const geometries = [[1320, 2760], [2760, 1320], [440, 920], [920, 440], [360, 800], [800, 360],
  [1920, 1080], [1080, 1920], [1024, 1024], [1, 1], [1, 4096], [4096, 1], [0.5, 1.25], [1.25, 0.5]];

check('portrait/landscape/square/extreme/fractional geometry partitions the entire screen without overlapping area', () => {
  for (const [width, height] of geometries) {
    verifyWedges(Array.from(edgeGlowWedges(width, height), wedge => ({
      start: [wedge.start.x, wedge.start.y], end: [wedge.end.x, wedge.end.y],
      points: Array.from(wedge.points, point => [point.x, point.y])
    })), width, height);
  }
  for (const [width, height] of [[0, 100], [100, 0], [-1, 100], [100, -1], [NaN, 100],
    [100, NaN], [Infinity, 100], [100, Infinity], [-Infinity, 100], [100, -Infinity]]) {
    assert.equal(edgeGlowWedges(width, height).length, 0);
  }
});

check('light/strong stops smoothly decrease from the edge to alpha zero at the center with no opaque band', () => {
  for (const strong of [false, true]) {
    const stops = Array.from(edgeGlowStops(strong));
    assert.deepEqual(stops.map(stop => stop.offset), [0, 0.08, 0.2, 0.45, 0.72, 1]);
    const intensity = strong ? 0.76 : 0.58;
    for (let index = 0; index < stops.length; index++) {
      near(stops[index].alpha, intensity * [1, 0.82, 0.48, 0.14, 0.025, 0][index]);
      assert.ok(stops[index].alpha >= 0 && stops[index].alpha < 1);
      if (index) assert.ok(stops[index].offset > stops[index - 1].offset &&
        stops[index].alpha < stops[index - 1].alpha);
    }
    assert.equal(stops.at(-1).alpha, 0);
  }
});

check('onReady gates drawing, onAreaChange redraws actual dimensions and detached callbacks cannot repaint', () => {
  const test = fixture(Level.LIGHT, {}, true, false);
  assert.equal(test.edge.canvasReady, false);
  assert.equal(test.edge.context.operations.length, 0);
  assert.equal(typeof test.edge.context.settings.antialias, 'boolean');
  test.edge.draw();
  test.area();
  assert.equal(test.edge.context.operations.length, 0);
  test.ready();
  assert.equal(test.edge.canvasReady, true);
  verifyDrawing(test);
  test.edge.context.width = 400;
  test.edge.context.height = 860;
  canvasHooks.call(test.edge).area();
  verifyDrawing(test);
  test.edge.aboutToDisappear();
  assert.equal(test.edge.canvasReady, false);
  const operations = test.edge.context.operations.length;
  test.edge.draw();
  test.edge.resizeDrawing();
  canvasHooks.call(test.edge).area();
  assert.equal(test.edge.context.operations.length, operations);
  test.edge.aboutToAppear();
  assert.equal(test.edge.canvasReady, false);
  test.ready();
  verifyDrawing(test);
});

check('px2vp window storage resizes 1320x2760 to 2760x1320 across the whole screen without restarting breathing', () => {
  const test = fixture(Level.SEVERE);
  assert.deepEqual(test.conversions, [1320, 2760]);
  assert.equal(test.edge.drawingWidth, 440);
  assert.equal(test.edge.drawingHeight, 920);
  verifyDrawing(test);
  test.finish();
  const pulse = test.current(), generation = test.edge.generation, count = test.animators.length;
  pulse.frame(0.94);
  for (const [width, height] of [[2760, 1320], [1320, 2760]]) {
    test.resize(width, height);
    assert.deepEqual(test.conversions.slice(-2), [width, height]);
    near(test.edge.drawingWidth * 3, width);
    near(test.edge.drawingHeight * 3, height);
    assert.deepEqual([test.edge.context.width, test.edge.context.height], [width / 3, height / 3]);
    verifyDrawing(test);
    assert.equal(test.current(), pulse);
    assert.equal(test.edge.generation, generation);
    assert.equal(test.animators.length, count);
    near(test.edge.edgeAlpha, 0.94);
  }
  const fallback = fixture(Level.NORMAL, { windowWidthPx: 0, windowHeightPx: 0 });
  assert.equal(fallback.edge.drawingWidth, '100%');
  assert.equal(fallback.edge.drawingHeight, '100%');
  assert.equal(fallback.conversions.length, 0);
  fallback.resize(1320, 2760);
  assert.equal(fallback.edge.drawingWidth, 440);
  assert.equal(fallback.edge.drawingHeight, 920);
  fallback.edge.aboutToDisappear();
  const conversions = fallback.conversions.length;
  Object.assign(fallback.edge, { windowWidthPx: 2760, windowHeightPx: 1320 });
  fallback.edge.resizeDrawing();
  assert.equal(fallback.conversions.length, conversions);
  assert.equal(fallback.edge.drawingWidth, 440);
  fallback.edge.aboutToAppear();
  fallback.ready();
  assert.equal(fallback.edge.drawingWidth, 920);
  assert.equal(fallback.edge.drawingHeight, 440);
});

check('Canvas draws actual model wedges and same-RGB alpha stops for every level and portrait/landscape geometry', () => {
  for (const level of levels) {
    const test = fixture(level);
    for (const [width, height] of geometries) {
      test.edge.context.width = width;
      test.edge.context.height = height;
      canvasHooks.call(test.edge).area();
      verifyDrawing(test);
    }
  }
});

check('resourceColor/rgba mocks redraw new theme shades and reduceMotion uses only the inset static stroke', () => {
  for (const reduceMotion of [false, true]) {
    for (const level of levels) {
      const test = fixture(level, { reduceMotion });
      const animator = test.edge.effectAnimator, generation = test.edge.generation;
      let previousColor;
      for (const mode of [0, 1, 0, 1]) {
        mockColorMode = mode;
        test.edge.colorMode = mode;
        test.snapshot();
        verifyDrawing(test);
        const color = reduceMotion ? test.edge.context.frame.strokes[0].color :
          test.edge.context.frame.gradients[0].stops[0].color;
        if (previousColor) assert.notDeepEqual(color, previousColor, 'Theme changes resolve a new shade');
        previousColor = { ...color };
        assert.equal(test.edge.effectAnimator, animator);
        assert.equal(test.edge.generation, generation);
        for (const [width, height] of [[2760, 1320], [1320, 2760]]) {
          test.resize(width, height);
          verifyDrawing(test);
        }
      }
    }
  }
});

check('static geometry stays finite with a setter-only lineWidth API and resource resolution uses the UI scope', () => {
  const before = scopedCalls;
  for (const level of levels) {
    const test = fixture(level, { reduceMotion: true });
    assert.equal(test.edge.context.lineWidth, undefined, 'Model the observed phone getter behavior');
    verifyDrawing(test);
    assert.equal(test.animators.length, 0);
    const width = level === Level.LIGHT ? 1.5 : 2;
    assert.equal(test.edge.context.appliedLineWidth, width);
    assert.deepEqual(test.edge.context.frame.strokes[0].rect,
      [width / 2, width / 2, test.edge.context.width - width, test.edge.context.height - width]);
  }
  assert.ok(scopedCalls > before);
  assert.equal(inUIScope, false);
});

check('normal/inactive/disabled Canvas clears without paint, and animated/static transitions never combine fill and border', () => {
  for (const props of [{}, { active: false }, { effectEnabled: false }, { reduceMotion: true }]) {
    const test = fixture(Level.NORMAL, props);
    assert.equal(test.edge.context.frame.fills.length, 0);
    assert.equal(test.edge.context.frame.strokes.length, 0);
  }
  for (const props of [{ active: false }, { effectEnabled: false }]) {
    const test = fixture(Level.SEVERE, props);
    assert.equal(test.edge.context.frame.fills.length, 0);
    assert.equal(test.edge.context.frame.strokes.length, 0);
  }
  const test = fixture(Level.LIGHT);
  test.finish();
  test.change({ reduceMotion: true });
  verifyDrawing(test);
  test.change({ level: Level.SEVERE });
  verifyDrawing(test);
  test.change({ reduceMotion: false });
  verifyDrawing(test);
  test.change({ level: Level.NORMAL });
  test.finish();
  assert.equal(test.edge.context.frame.fills.length, 0);
  assert.equal(test.edge.context.frame.strokes.length, 0);
});

check('normal, initially inactive/disabled and detached watches never create an effect', () => {
  const normal = fixture();
  assert.equal(normal.animators.length, 0);
  assert.equal(normal.edge.edgeAlpha, 0);
  assert.equal(normal.edge.renderedLevel, Level.NORMAL);
  for (const test of [fixture(Level.LIGHT, { active: false }),
    fixture(Level.SEVERE, { effectEnabled: false }), fixture(Level.MEDIUM, {}, false)]) {
    assert.equal(test.animators.length, 0);
    assert.equal(test.edge.edgeAlpha, 0);
    assert.equal(test.edge.renderedLevel, Level.NORMAL);
    test.change({ level: Level.SEVERE });
    assert.equal(test.animators.length, 0);
  }
});

for (const level of levels) {
  check(`${Level[level]} breathes with ${level === Level.LIGHT ? 1500 : 1000}ms half-cycle and one rendered level`, () => {
    const test = fixture(level);
    const entry = test.current();
    assert.equal(entry.options.duration, 250);
    assert.equal(entry.options.iterations, 1);
    test.finish();
    const pulse = test.current();
    const begin = level === Level.LIGHT ? 0.3 : 0.38;
    const end = level === Level.LIGHT ? 0.78 : 0.94;
    assert.deepEqual(pulse.options, {
      duration: level === Level.LIGHT ? 1500 : 1000, easing: 'ease-in-out', delay: 0,
      fill: 'forwards', direction: 'alternate', iterations: -1, begin, end
    });
    assert.equal(entry.cancelCalls, 1);
    assert.equal(pulse.playCalls, 1);
    for (const alpha of [begin, (begin + end) / 2, end, (begin + end) / 2, begin]) {
      pulse.frame(alpha);
      near(test.edge.edgeAlpha, alpha);
      assert.equal(test.edge.renderedLevel, level);
      assert.deepEqual(test.snapshot().layers, [colorFor(level)]);
    }
    replayStale(test, [entry]);
  });
}

check('normal recovery fades for 250ms, retaining the old level until zero and then releasing the animator', () => {
  for (const level of levels) {
    const test = fixture(level);
    test.finish();
    const pulse = test.current();
    pulse.frame(pulse.options.end);
    const alpha = test.edge.edgeAlpha;
    test.change({ level: Level.NORMAL });
    const fade = test.current();
    assert.equal(pulse.cancelCalls, 1);
    near(test.edge.edgeAlpha, alpha);
    assert.equal(fade.options.duration, 250);
    assert.equal(fade.options.direction, 'normal');
    assert.equal(fade.options.iterations, 1);
    for (const progress of [0, 0.25, 0.5, 0.75, 1]) {
      fade.frame(progress);
      near(test.edge.edgeAlpha, alpha * (1 - progress));
      assert.equal(test.edge.renderedLevel, level);
    }
    test.finish();
    assert.equal(test.edge.edgeAlpha, 0);
    assert.equal(test.edge.renderedLevel, Level.NORMAL);
    assert.equal(test.edge.effectAnimator, undefined);
    replayStale(test, test.animators);
  }
});

check('light/strong switches use 125ms out plus 125ms in, changing the only rendered level at zero', () => {
  for (const [from, to] of [[Level.LIGHT, Level.MEDIUM], [Level.LIGHT, Level.SEVERE],
    [Level.MEDIUM, Level.LIGHT], [Level.SEVERE, Level.LIGHT]]) {
    const test = fixture(from);
    test.finish();
    const oldPulse = test.current();
    oldPulse.frame(oldPulse.options.end);
    const startAlpha = test.edge.edgeAlpha;
    test.samples.length = 0;
    test.change({ level: to });
    const fadeOut = test.current();
    assert.equal(fadeOut.options.duration, 125);
    near(test.edge.edgeAlpha, startAlpha);
    for (const progress of [0, 0.5, 1]) {
      fadeOut.frame(progress);
      near(test.edge.edgeAlpha, startAlpha * (1 - progress));
      assert.equal(test.edge.renderedLevel, from);
    }
    test.finish();
    const fadeIn = test.current();
    assert.equal(fadeIn.options.duration, 125);
    assert.equal(fadeOut.options.duration + fadeIn.options.duration, 250);
    assert.equal(test.edge.edgeAlpha, 0);
    assert.equal(test.edge.renderedLevel, to);
    assert.deepEqual(test.snapshot().layers, []);
    replayStale(test, [oldPulse, fadeOut]);
    const targetAlpha = to === Level.LIGHT ? 0.3 : 0.38;
    for (const progress of [0, 0.5, 1]) {
      fadeIn.frame(progress);
      near(test.edge.edgeAlpha, targetAlpha * progress);
      assert.equal(test.edge.renderedLevel, to);
    }
    assert.ok(test.samples.some(state => state.alpha === 0 && state.renderedLevel === from));
    assert.ok(test.samples.some(state => state.alpha === 0 && state.renderedLevel === to));
    test.finish();
    assert.equal(test.current().options.iterations, -1);
    replayStale(test, [oldPulse, fadeOut, fadeIn]);
  }
});

check('medium/severe share one strong visual and the 1000ms half-cycle without a two-layer crossfade', () => {
  for (const [from, to] of [[Level.MEDIUM, Level.SEVERE], [Level.SEVERE, Level.MEDIUM]]) {
    const test = fixture(from);
    test.finish();
    const pulse = test.current();
    pulse.frame(0.94);
    test.change({ level: to });
    near(test.edge.edgeAlpha, 0.94);
    assert.equal(test.edge.renderedLevel, to);
    assert.deepEqual(test.snapshot().layers, [strongColor]);
    assert.equal(test.current().options.duration, 250);
    test.current().frame(0.5);
    near(test.edge.edgeAlpha, 0.66);
    test.finish();
    assert.equal(test.current().options.duration, 1000);
    replayStale(test, test.animators.slice(0, -1));
  }
});

check('reduceMotion is immediately static, creates no animation and cancels every animated phase', () => {
  for (const level of [Level.NORMAL, ...levels]) {
    const test = fixture(level, { reduceMotion: true });
    for (const next of [level, Level.SEVERE, Level.LIGHT, Level.MEDIUM, Level.NORMAL]) {
      test.change({ level: next });
      assert.equal(test.edge.renderedLevel, next);
      near(test.edge.edgeAlpha, next === Level.NORMAL ? 0 : next === Level.LIGHT ? 0.5 : 0.72);
      assert.equal(test.edge.effectAnimator, undefined);
      assert.equal(test.animators.length, 0);
    }
  }
  for (const phase of phases) {
    const test = inPhase(phase);
    const old = test.current();
    const count = test.animators.length;
    test.change({ reduceMotion: true });
    assert.equal(old.cancelCalls, 1);
    assert.equal(test.animators.length, count);
    assert.equal(test.edge.effectAnimator, undefined);
    assert.equal(test.edge.renderedLevel, test.edge.level);
    near(test.edge.edgeAlpha, test.edge.level === Level.NORMAL ? 0 : test.edge.level === Level.LIGHT ? 0.5 : 0.72);
    replayStale(test, test.animators);
    test.change({ level: Level.MEDIUM });
    test.change({ reduceMotion: false });
    assert.equal(test.current().options.duration, 250);
    replayStale(test, test.animators.slice(0, count));
    test.finish();
    assert.equal(test.current().options.duration, 1000);
  }
});

for (const prop of ['active', 'effectEnabled']) {
  check(`${prop}=false immediately clears/cancels all phases; old callbacks cannot replace a restarted animator`, () => {
    for (const level of levels) {
      for (const phase of phases) {
        const test = inPhase(phase, level);
        const obsolete = test.current();
        const old = test.animators.slice();
        test.change({ [prop]: false });
        assert.equal(obsolete.cancelCalls, 1);
        assert.equal(test.edge.edgeAlpha, 0);
        assert.equal(test.edge.renderedLevel, Level.NORMAL);
        assert.equal(test.edge.effectAnimator, undefined);
        replayStale(test, old);
        test.change({ [prop]: true, level: Level.SEVERE });
        const replacement = test.current();
        assert.notEqual(replacement, obsolete);
        replayStale(test, old);
        assert.equal(test.current(), replacement);
        test.finish();
        replayStale(test, [...old, replacement]);
      }
    }
  });
}

check('aboutToDisappear cancels/clears all phases; detached watches and callbacks cannot revive the instance', () => {
  for (const level of levels) {
    for (const phase of phases) {
      const test = inPhase(phase, level);
      const obsolete = test.current();
      const old = test.animators.slice();
      test.edge.aboutToDisappear();
      assert.equal(obsolete.cancelCalls, 1);
      assert.equal(test.edge.attached, false);
      assert.equal(test.edge.edgeAlpha, 0);
      assert.equal(test.edge.renderedLevel, Level.NORMAL);
      assert.equal(test.edge.effectAnimator, undefined);
      replayStale(test, old);
      const count = test.animators.length;
      test.change({ level: Level.SEVERE });
      assert.equal(test.animators.length, count);
      test.edge.aboutToAppear();
      test.snapshot();
      const replacement = test.current();
      replayStale(test, old);
      assert.equal(test.current(), replacement);
      test.finish();
      replayStale(test, [...old, replacement]);
    }
  }
});

check('rapid level changes isolate every generation and keep exactly one rendered effect/animator', () => {
  const test = fixture(Level.LIGHT);
  test.finish();
  test.current().frame(0.78);
  for (const next of [Level.MEDIUM, Level.SEVERE, Level.LIGHT, Level.NORMAL, Level.SEVERE, Level.LIGHT]) {
    const old = test.animators.slice();
    test.change({ level: next });
    const current = test.current();
    current.frame(0.25);
    replayStale(test, old);
    assert.equal(test.current(), current);
  }
  const old = test.animators.slice();
  test.finish();
  replayStale(test, old);
  assert.equal(test.current().options.duration, 1500);
  assert.equal(test.edge.renderedLevel, Level.LIGHT);
});

check('permanent overlay and isolated preview have independent animators, rendered levels and generations', () => {
  const main = fixture(Level.SEVERE);
  const preview = fixture(Level.LIGHT);
  main.finish();
  preview.finish();
  preview.current().frame(0.6);
  const previewState = preview.snapshot();
  const old = main.animators.slice();
  main.change({ active: false });
  replayStale(main, old);
  assert.deepEqual(preview.snapshot(), previewState);
  main.change({ active: true });
  main.finish();
  assert.deepEqual(preview.snapshot(), previewState);
  const mainState = main.snapshot();
  preview.edge.aboutToDisappear();
  preview.snapshot();
  assert.deepEqual(main.snapshot(), mainState);
});

console.log(`PASS: ${checks} edge-light offline test groups; ${canvasDraws} Canvas draws; ${partitionProbes} partition probes; 0 failures`);
