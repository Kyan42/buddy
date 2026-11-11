// Clicky's board: a whiteboard window where Claude draws figures, graphs and
// equations while it talks.
//
// Claude writes short JavaScript snippets (<draw>...</draw> in its reply)
// against the small API below. The app runs each snippet the moment the voice
// reaches it (clickyBoard.runStep), and everything that snippet draws is
// revealed like a pen stroke, spread over the time the voice spends on that
// sentence (durationSeconds comes from the app).
//
// Board space is always 1000 x 625 units, origin top-left, y grows down. The
// window scales it to fit.
//
// Snippets share one scope per board: a name assigned without let/const
// (tri = polygon(...)) stays available to later snippets until the board is
// cleared. This page has no network access (see the CSP in clicky-board.html).
(function () {
  'use strict';

  const BOARD_WIDTH = 1000;
  const BOARD_HEIGHT = 625;
  const SVG_NAMESPACE = 'http://www.w3.org/2000/svg';

  const boardStage = document.getElementById('board-stage');
  const inkLayer = document.getElementById('ink-layer');
  const wordsLayer = document.getElementById('words-layer');
  const highlightLayer = document.getElementById('highlight-layer');
  const roughSvgPainter = rough.svg(inkLayer);

  const NAMED_COLORS = {
    ink: '#2B2D33',
    accent: '#3380FF',
    blue: '#3380FF',
    red: '#E03131',
    green: '#2F9E44',
    orange: '#F08C00',
    purple: '#7048E8',
    grey: '#868E96',
    gray: '#868E96',
    yellow: '#F2B705',
  };

  function resolveColor(colorNameOrHex, fallbackColor) {
    if (!colorNameOrHex) return fallbackColor;
    if (NAMED_COLORS[colorNameOrHex]) return NAMED_COLORS[colorNameOrHex];
    if (/^#[0-9a-fA-F]{3,8}$/.test(colorNameOrHex)) return colorNameOrHex;
    return fallbackColor;
  }

  function colorWithAlpha(hexColor, alpha) {
    let hexDigits = hexColor.replace('#', '');
    if (hexDigits.length === 3) hexDigits = hexDigits.split('').map(digit => digit + digit).join('');
    const red = parseInt(hexDigits.slice(0, 2), 16);
    const green = parseInt(hexDigits.slice(2, 4), 16);
    const blue = parseInt(hexDigits.slice(4, 6), 16);
    return `rgba(${red}, ${green}, ${blue}, ${alpha})`;
  }

  // ------------------------------------------------------------ fitting the board to the window

  function fitBoardStageToWindow() {
    const scale = Math.min(window.innerWidth / BOARD_WIDTH, window.innerHeight / BOARD_HEIGHT);
    const offsetX = (window.innerWidth - BOARD_WIDTH * scale) / 2;
    const offsetY = (window.innerHeight - BOARD_HEIGHT * scale) / 2;
    boardStage.style.transform = `translate(${offsetX}px, ${offsetY}px) scale(${scale})`;
  }
  window.addEventListener('resize', fitBoardStageToWindow);
  fitBoardStageToWindow();

  // ------------------------------------------------------------ point helpers

  function requirePoint(candidate, description) {
    if (!Array.isArray(candidate) || candidate.length < 2 || !isFinite(candidate[0]) || !isFinite(candidate[1])) {
      throw new Error(`${description} must be a point like [x, y]`);
    }
    return [Number(candidate[0]), Number(candidate[1])];
  }
  const addPoints = (pointA, pointB) => [pointA[0] + pointB[0], pointA[1] + pointB[1]];
  const subtractPoints = (pointA, pointB) => [pointA[0] - pointB[0], pointA[1] - pointB[1]];
  const scalePoint = (point, factor) => [point[0] * factor, point[1] * factor];
  const pointLength = point => Math.hypot(point[0], point[1]);
  const unitVector = point => {
    const length = pointLength(point);
    return length < 1e-9 ? [0, 0] : [point[0] / length, point[1] / length];
  };
  const midpoint = (pointA, pointB) => [(pointA[0] + pointB[0]) / 2, (pointA[1] + pointB[1]) / 2];
  const formatPoint = point => `${point[0].toFixed(1)},${point[1].toFixed(1)}`;

  function boxOfPoints(points) {
    const xs = points.map(point => point[0]);
    const ys = points.map(point => point[1]);
    const minX = Math.min(...xs), minY = Math.min(...ys);
    return [minX, minY, Math.max(...xs) - minX, Math.max(...ys) - minY];
  }

  // ------------------------------------------------------------ parts and the reveal queue

  // Everything one snippet draws is queued here, then revealed in order over
  // the step's duration once the snippet finishes running.
  let itemsToRevealInCurrentStep = [];
  let runningRevealAnimations = [];
  let partsOnBoard = [];
  let nextPartNumber = 1;
  let mostRecentAxes = null;

  function makePart(kind, elements, box) {
    const part = {
      id: 'p' + nextPartNumber++,
      kind,
      elements,
      box,
      center: [box[0] + box[2] / 2, box[1] + box[3] / 2],
    };
    partsOnBoard.push(part);
    return part;
  }

  function queueStrokeReveal(svgGroup) {
    // rough.js puts a shape's fill before its outline. A hand-drawn figure reads
    // better outline first, then shading, so fill strokes (whose colour is the
    // translucent rgba fill) are revealed last and get a smaller share of time.
    const strokePaths = Array.from(svgGroup.querySelectorAll('path'));
    const isFillSketchPath = strokePath => (strokePath.getAttribute('stroke') || '').startsWith('rgba');
    const orderedPaths = strokePaths.filter(strokePath => !isFillSketchPath(strokePath))
      .concat(strokePaths.filter(isFillSketchPath));
    let revealWeight = 0;
    const pathsWithLengths = orderedPaths.map(strokePath => {
      const isFilledShape = strokePath.getAttribute('fill') && strokePath.getAttribute('fill') !== 'none'
        && (!strokePath.getAttribute('stroke') || strokePath.getAttribute('stroke') === 'none');
      const pathLength = isFilledShape ? 120 : Math.max(1, strokePath.getTotalLength());
      const pathWeight = isFilledShape ? 40 : isFillSketchPath(strokePath) ? Math.min(pathLength * 0.12, 260) : pathLength;
      revealWeight += pathWeight;
      return { strokePath, pathLength, isFilledShape, pathWeight };
    });
    itemsToRevealInCurrentStep.push({ kind: 'strokes', pathsWithLengths, revealWeight: Math.max(40, revealWeight) });
  }

  function queueWipeReveal(element, revealWeight) {
    itemsToRevealInCurrentStep.push({ kind: 'wipe', element, revealWeight: Math.max(40, revealWeight) });
  }

  function rememberAnimation(animation) {
    runningRevealAnimations.push(animation);
    animation.onfinish = () => {
      runningRevealAnimations = runningRevealAnimations.filter(running => running !== animation);
    };
  }

  // Reveals the queued items one after another across durationSeconds, each
  // getting time in proportion to how much ink it has.
  function revealQueuedItems(durationSeconds) {
    const queuedItems = itemsToRevealInCurrentStep;
    itemsToRevealInCurrentStep = [];
    if (queuedItems.length === 0) return;

    const totalDurationMs = Math.max(0, durationSeconds) * 1000;
    const totalWeight = queuedItems.reduce((sum, item) => sum + item.revealWeight, 0);
    let itemStartMs = 0;

    for (const item of queuedItems) {
      const itemDurationMs = totalDurationMs === 0 ? 0 : Math.max(120, totalDurationMs * item.revealWeight / totalWeight);

      if (item.kind === 'strokes') {
        const itemInkWeight = item.pathsWithLengths.reduce((sum, path) => sum + path.pathWeight, 0) || 1;
        let pathStartMs = itemStartMs;
        for (const { strokePath, pathLength, isFilledShape, pathWeight } of item.pathsWithLengths) {
          const pathDurationMs = itemDurationMs * pathWeight / itemInkWeight;
          if (isFilledShape) {
            rememberAnimation(strokePath.animate(
              [{ opacity: 0 }, { opacity: 1 }],
              { duration: Math.max(1, pathDurationMs), delay: pathStartMs, fill: 'both', easing: 'ease-out' }
            ));
          } else {
            strokePath.style.strokeDasharray = `${pathLength} ${pathLength}`;
            rememberAnimation(strokePath.animate(
              [{ strokeDashoffset: pathLength }, { strokeDashoffset: 0 }],
              { duration: Math.max(1, pathDurationMs), delay: pathStartMs, fill: 'both', easing: 'ease-in-out' }
            ));
          }
          pathStartMs += pathDurationMs;
        }
      } else {
        rememberAnimation(item.element.animate(
          [
            { clipPath: 'inset(-20% 100% -20% -2%)', opacity: 0.2 },
            { clipPath: 'inset(-20% -2% -20% -2%)', opacity: 1 },
          ],
          { duration: Math.max(1, itemDurationMs), delay: itemStartMs, fill: 'both', easing: 'ease-out' }
        ));
      }
      itemStartMs += itemDurationMs;
    }
  }

  function finishAllRunningAnimations() {
    for (const animation of runningRevealAnimations.slice()) {
      try { animation.finish(); } catch (finishError) { /* already removed from the page */ }
    }
    runningRevealAnimations = [];
  }

  // ------------------------------------------------------------ rough.js strokes

  function roughOptions(drawOptions, extraOptions) {
    const strokeColor = resolveColor(drawOptions.color, NAMED_COLORS.ink);
    const roughStyle = {
      stroke: strokeColor,
      strokeWidth: drawOptions.width || 2.6,
      roughness: drawOptions.roughness == null ? 1.1 : drawOptions.roughness,
      bowing: 1.2,
      disableMultiStroke: true,
      // Keeps segment ends joined, so rounded corners don't show gaps.
      preserveVertices: true,
      seed: Math.floor(Math.random() * 2 ** 31),
      ...extraOptions,
    };
    if (drawOptions.dashed) roughStyle.strokeLineDash = [10, 9];
    if (drawOptions.fill) {
      const fillColor = resolveColor(drawOptions.fill, strokeColor);
      roughStyle.fill = drawOptions.fillStyle === 'solid' ? colorWithAlpha(fillColor, 0.28) : colorWithAlpha(fillColor, 0.75);
      roughStyle.fillStyle = drawOptions.fillStyle || 'hachure';
      roughStyle.fillWeight = 1.3;
      roughStyle.hachureGap = 7;
    }
    return roughStyle;
  }

  function addRoughShape(roughGroup) {
    inkLayer.appendChild(roughGroup);
    queueStrokeReveal(roughGroup);
    return roughGroup;
  }

  function makeSvgGroup(childGroups) {
    const svgGroup = document.createElementNS(SVG_NAMESPACE, 'g');
    childGroups.forEach(childGroup => svgGroup.appendChild(childGroup));
    return svgGroup;
  }

  // ------------------------------------------------------------ words (text, math, tables)

  function makeWordsElement(drawOptions, defaultFont) {
    const wordsElement = document.createElement('div');
    const fontStyle = drawOptions.font || defaultFont;
    wordsElement.className = 'board-words ' + (fontStyle === 'clean' ? 'clean' : 'hand');
    const defaultSize = fontStyle === 'clean' ? 22 : 36;
    wordsElement.style.fontSize = (drawOptions.size || defaultSize) + 'px';
    wordsElement.style.color = resolveColor(drawOptions.color, NAMED_COLORS.ink);
    if (drawOptions.bold) wordsElement.style.fontWeight = '700';
    if (drawOptions.maxWidth) {
      wordsElement.classList.add('wraps');
      wordsElement.style.width = drawOptions.maxWidth + 'px';
    }
    return wordsElement;
  }

  // Places an element so `anchorPoint` sits at the spot named by align
  // (left/center/right) and valign (top/middle/bottom). Returns its box.
  function placeWordsElement(wordsElement, anchorPoint, align, valign) {
    wordsLayer.appendChild(wordsElement);
    const elementWidth = wordsElement.offsetWidth;
    const elementHeight = wordsElement.offsetHeight;
    const requestedLeft = anchorPoint[0] - (align === 'center' ? elementWidth / 2 : align === 'right' ? elementWidth : 0);
    const requestedTop = anchorPoint[1] - (valign === 'middle' ? elementHeight / 2 : valign === 'bottom' ? elementHeight : 0);
    // Claude often guesses an anchor that pushes long words past the edge
    // (a centered-looking equation anchored at its left end), so slide the
    // words back inside the board rather than cutting them off.
    const left = keepInsideBoard(requestedLeft, elementWidth, BOARD_WIDTH);
    const top = keepInsideBoard(requestedTop, elementHeight, BOARD_HEIGHT);
    wordsElement.style.left = left + 'px';
    wordsElement.style.top = top + 'px';
    return [left, top, elementWidth, elementHeight];
  }

  function keepInsideBoard(requestedStart, size, boardSize) {
    const edgeMargin = 8;
    if (size >= boardSize - edgeMargin * 2) return edgeMargin;
    return Math.min(Math.max(requestedStart, edgeMargin), boardSize - edgeMargin - size);
  }

  // Places words just outside `anchorPoint` in `direction` (a unit vector),
  // far enough that the words don't sit on top of the thing they name.
  function placeWordsAwayFrom(wordsElement, anchorPoint, direction, gap) {
    wordsLayer.appendChild(wordsElement);
    const elementWidth = wordsElement.offsetWidth;
    const elementHeight = wordsElement.offsetHeight;
    const distance = (gap == null ? 10 : gap) + Math.abs(direction[0]) * elementWidth / 2 + Math.abs(direction[1]) * elementHeight / 2;
    const center = addPoints(anchorPoint, scalePoint(direction, distance));
    return placeWordsElement(wordsElement, center, 'center', 'middle');
  }

  // A single backslash in a JavaScript string turns "\frac" into a form feed
  // plus "rac", "\theta" into a tab plus "heta", and so on. Turn those control
  // characters back into the backslash commands they came from.
  const CONTROL_CHARACTERS_FROM_LOST_BACKSLASHES = { '\f': '\\f', '\t': '\\t', '\n': '\\n', '\r': '\\r', '\b': '\\b', '\v': '\\v' };
  function repairLostLatexBackslashes(latexSource) {
    return String(latexSource).replace(/[\f\t\n\r\b\v](?=[a-zA-Z])/g, controlCharacter => CONTROL_CHARACTERS_FROM_LOST_BACKSLASHES[controlCharacter]);
  }

  function fillWithMath(wordsElement, latexSource) {
    // \displaystyle keeps fractions and sums full size, as on a whiteboard.
    katex.render('\\displaystyle ' + repairLostLatexBackslashes(latexSource), wordsElement, { throwOnError: false, output: 'html' });
  }

  const SIDE_DIRECTIONS = {
    above: [0, -1], below: [0, 1], left: [-1, 0], right: [1, 0],
    'above-right': unitVector([1, -1]), 'above-left': unitVector([-1, -1]),
    'below-right': unitVector([1, 1]), 'below-left': unitVector([-1, 1]),
  };

  function makeWordsPart(kind, wordsElement, box, revealWeight) {
    queueWipeReveal(wordsElement, revealWeight);
    return makePart(kind, [wordsElement], box);
  }

  // ------------------------------------------------------------ the drawing API Claude uses

  const boardApi = {};

  boardApi.text = function (at, words, drawOptions = {}) {
    const anchorPoint = requirePoint(at, 'text(at, words): at');
    const wordsElement = makeWordsElement(drawOptions, 'hand');
    wordsElement.textContent = String(words);
    const box = placeWordsElement(wordsElement, anchorPoint, drawOptions.align || 'left', drawOptions.valign || 'top');
    return makeWordsPart('text', wordsElement, box, String(words).length * 14);
  };

  boardApi.math = function (at, latexSource, drawOptions = {}) {
    const anchorPoint = requirePoint(at, 'math(at, latex): at');
    const wordsElement = makeWordsElement({ size: 28, ...drawOptions }, 'clean');
    fillWithMath(wordsElement, latexSource);
    const box = placeWordsElement(wordsElement, anchorPoint, drawOptions.align || 'left', drawOptions.valign || 'top');
    return makeWordsPart('math', wordsElement, box, box[2] * 0.9);
  };

  boardApi.table = function (at, rows, drawOptions = {}) {
    const anchorPoint = requirePoint(at, 'table(at, rows): at');
    if (!Array.isArray(rows) || !rows.every(Array.isArray)) throw new Error('table(at, rows): rows must be a list of rows, like [["x", "y"], [1, 2]]');
    const wordsElement = makeWordsElement({ size: 26, ...drawOptions }, 'hand');
    const tableElement = document.createElement('table');
    tableElement.className = 'board-table';
    rows.forEach((row, rowIndex) => {
      const tableRow = document.createElement('tr');
      row.forEach(cellValue => {
        const tableCell = document.createElement('td');
        const cellText = String(cellValue);
        // Cells wrapped in $...$ are typeset as math.
        if (/^\$.*\$$/.test(cellText)) fillWithMath(tableCell, cellText.slice(1, -1));
        else tableCell.textContent = cellText;
        if (rowIndex === 0 && drawOptions.header !== false) tableCell.classList.add('header');
        tableRow.appendChild(tableCell);
      });
      tableElement.appendChild(tableRow);
    });
    wordsElement.appendChild(tableElement);
    const box = placeWordsElement(wordsElement, anchorPoint, drawOptions.align || 'left', drawOptions.valign || 'top');
    return makeWordsPart('table', wordsElement, box, box[2] * box[3] / 60);
  };

  boardApi.line = function (from, to, drawOptions = {}) {
    return drawLineOrArrow(requirePoint(from, 'line(from, to): from'), requirePoint(to, 'line(from, to): to'), drawOptions, false);
  };

  boardApi.arrow = function (from, to, drawOptions = {}) {
    return drawLineOrArrow(requirePoint(from, 'arrow(from, to): from'), requirePoint(to, 'arrow(from, to): to'), drawOptions, true);
  };

  function drawLineOrArrow(startPoint, endPoint, drawOptions, hasArrowhead) {
    const lineVector = subtractPoints(endPoint, startPoint);
    const lineLength = pointLength(lineVector);
    // Perpendicular to the line; `curve` bends the line toward this side.
    const lineNormal = unitVector([-lineVector[1], lineVector[0]]);
    const curveAmount = drawOptions.curve || 0;
    const controlPoint = addPoints(midpoint(startPoint, endPoint), scalePoint(lineNormal, curveAmount * lineLength * 0.35));
    const shapeOptions = roughOptions(drawOptions);

    const strokeGroups = [];
    if (curveAmount === 0) {
      strokeGroups.push(roughSvgPainter.line(startPoint[0], startPoint[1], endPoint[0], endPoint[1], shapeOptions));
    } else {
      strokeGroups.push(roughSvgPainter.path(`M ${formatPoint(startPoint)} Q ${formatPoint(controlPoint)} ${formatPoint(endPoint)}`, shapeOptions));
    }

    function addArrowhead(tipPoint, comingFromPoint) {
      const headDirection = unitVector(subtractPoints(tipPoint, comingFromPoint));
      const headLength = Math.min(18, lineLength * 0.4);
      const sideA = addPoints(tipPoint, scalePoint(rotateVector(headDirection, 0.45), -headLength));
      const sideB = addPoints(tipPoint, scalePoint(rotateVector(headDirection, -0.45), -headLength));
      strokeGroups.push(roughSvgPainter.linearPath([sideA, tipPoint, sideB], { ...shapeOptions, roughness: 0.5, strokeLineDash: undefined }));
    }
    if (hasArrowhead) addArrowhead(endPoint, curveAmount === 0 ? startPoint : controlPoint);
    if (hasArrowhead && drawOptions.bothEnds) addArrowhead(startPoint, curveAmount === 0 ? endPoint : controlPoint);

    const svgGroup = addRoughShape(makeSvgGroup(strokeGroups));
    const part = makePart(hasArrowhead ? 'arrow' : 'line', [svgGroup], boxOfPoints([startPoint, endPoint, controlPoint]));
    part.from = startPoint;
    part.to = endPoint;
    part.mid = curveAmount === 0 ? midpoint(startPoint, endPoint) : midpoint(midpoint(startPoint, controlPoint), midpoint(controlPoint, endPoint));
    if (drawOptions.label != null) {
      const labelSide = curveAmount < 0 ? scalePoint(lineNormal, -1) : lineNormal;
      // Prefer putting the label above a flat line rather than below it.
      const labelDirection = curveAmount === 0 && labelSide[1] > 0 ? scalePoint(labelSide, -1) : labelSide;
      const labelElement = makeWordsElement({ size: 30, color: drawOptions.labelColor || drawOptions.color }, 'hand');
      labelElement.textContent = String(drawOptions.label);
      placeWordsAwayFrom(labelElement, part.mid, labelDirection, 6);
      queueWipeReveal(labelElement, String(drawOptions.label).length * 14);
      part.elements.push(labelElement);
    }
    return part;
  }

  function rotateVector(vector, angleRadians) {
    const cosine = Math.cos(angleRadians), sine = Math.sin(angleRadians);
    return [vector[0] * cosine - vector[1] * sine, vector[0] * sine + vector[1] * cosine];
  }

  function addCenteredLabelInside(part, labelText, drawOptions) {
    const labelElement = makeWordsElement({ size: drawOptions.labelSize || 32, color: drawOptions.labelColor || drawOptions.color }, drawOptions.labelFont || 'hand');
    if (drawOptions.labelMath) fillWithMath(labelElement, labelText);
    else labelElement.textContent = String(labelText);
    fitLabelInsideShape(labelElement, part.box);
    placeWordsElement(labelElement, part.center, 'center', 'middle');
    queueWipeReveal(labelElement, String(labelText).length * 14);
    part.elements.push(labelElement);
  }

  // A label longer than its box wraps onto more lines, and shrinks if the
  // lines still don't fit, so the words stay inside the shape they name.
  function fitLabelInsideShape(labelElement, shapeBox) {
    const availableWidth = Math.max(shapeBox[2] - 24, 40);
    const availableHeight = Math.max(shapeBox[3] - 12, 20);
    wordsLayer.appendChild(labelElement);
    if (labelElement.offsetWidth > availableWidth) {
      labelElement.classList.add('wraps');
      labelElement.style.width = availableWidth + 'px';
      labelElement.style.textAlign = 'center';
    }
    let fontSize = parseFloat(labelElement.style.fontSize);
    const smallestReadableFontSize = 18;
    while (labelElement.offsetHeight > availableHeight && fontSize > smallestReadableFontSize) {
      fontSize -= 2;
      labelElement.style.fontSize = fontSize + 'px';
    }
  }

  boardApi.box = function (x, y, width, height, drawOptions = {}) {
    if (![x, y, width, height].every(value => isFinite(value))) throw new Error('box(x, y, w, h): all four must be numbers');
    const shapeOptions = roughOptions(drawOptions);
    const roughGroup = drawOptions.round
      ? roughSvgPainter.path(roundedRectanglePath(x, y, width, height, Math.min(18, width / 4, height / 4)), shapeOptions)
      : roughSvgPainter.rectangle(x, y, width, height, shapeOptions);
    const part = makePart('box', [addRoughShape(roughGroup)], [x, y, width, height]);
    if (drawOptions.label != null) addCenteredLabelInside(part, drawOptions.label, drawOptions);
    return part;
  };

  function roundedRectanglePath(x, y, width, height, radius) {
    return `M ${x + radius} ${y} H ${x + width - radius} Q ${x + width} ${y} ${x + width} ${y + radius} V ${y + height - radius} Q ${x + width} ${y + height} ${x + width - radius} ${y + height} H ${x + radius} Q ${x} ${y + height} ${x} ${y + height - radius} V ${y + radius} Q ${x} ${y} ${x + radius} ${y} Z`;
  }

  boardApi.circle = function (center, radius, drawOptions = {}) {
    const centerPoint = requirePoint(center, 'circle(center, radius): center');
    if (!isFinite(radius)) throw new Error('circle(center, radius): radius must be a number');
    const roughGroup = roughSvgPainter.circle(centerPoint[0], centerPoint[1], radius * 2, roughOptions(drawOptions));
    const part = makePart('circle', [addRoughShape(roughGroup)], [centerPoint[0] - radius, centerPoint[1] - radius, radius * 2, radius * 2]);
    part.radius = radius;
    if (drawOptions.label != null) addCenteredLabelInside(part, drawOptions.label, drawOptions);
    return part;
  };

  boardApi.ellipse = function (center, radiusX, radiusY, drawOptions = {}) {
    const centerPoint = requirePoint(center, 'ellipse(center, rx, ry): center');
    const roughGroup = roughSvgPainter.ellipse(centerPoint[0], centerPoint[1], radiusX * 2, radiusY * 2, roughOptions(drawOptions));
    const part = makePart('ellipse', [addRoughShape(roughGroup)], [centerPoint[0] - radiusX, centerPoint[1] - radiusY, radiusX * 2, radiusY * 2]);
    if (drawOptions.label != null) addCenteredLabelInside(part, drawOptions.label, drawOptions);
    return part;
  };

  boardApi.polygon = function (points, drawOptions = {}) {
    if (!Array.isArray(points) || points.length < 3) throw new Error('polygon(points): needs at least 3 points like [[x, y], ...]');
    const cornerPoints = points.map((point, pointIndex) => requirePoint(point, `polygon point ${pointIndex}`));
    const roughGroup = roughSvgPainter.polygon(cornerPoints, roughOptions(drawOptions));
    const part = makePart('polygon', [addRoughShape(roughGroup)], boxOfPoints(cornerPoints));
    const centroid = scalePoint(cornerPoints.reduce(addPoints, [0, 0]), 1 / cornerPoints.length);
    part.points = cornerPoints;
    part.center = centroid;
    part.vertex = vertexIndex => cornerPoints[((vertexIndex % cornerPoints.length) + cornerPoints.length) % cornerPoints.length];
    // side(i) runs from vertex i to vertex i+1, with an outward direction for labels.
    part.side = sideIndex => {
      const sideStart = part.vertex(sideIndex);
      const sideEnd = part.vertex(sideIndex + 1);
      const sideMid = midpoint(sideStart, sideEnd);
      let outward = unitVector([-(sideEnd[1] - sideStart[1]), sideEnd[0] - sideStart[0]]);
      if (outward[0] * (sideMid[0] - centroid[0]) + outward[1] * (sideMid[1] - centroid[1]) < 0) outward = scalePoint(outward, -1);
      return { a: sideStart, b: sideEnd, mid: sideMid, outward, length: pointLength(subtractPoints(sideEnd, sideStart)) };
    };
    return part;
  };

  boardApi.curve = function (points, drawOptions = {}) {
    if (!Array.isArray(points) || points.length < 2) throw new Error('curve(points): needs at least 2 points');
    const curvePoints = points.map((point, pointIndex) => requirePoint(point, `curve point ${pointIndex}`));
    const roughGroup = roughSvgPainter.curve(curvePoints, roughOptions(drawOptions, { roughness: drawOptions.roughness == null ? 0.6 : drawOptions.roughness }));
    const part = makePart('curve', [addRoughShape(roughGroup)], boxOfPoints(curvePoints));
    part.points = curvePoints;
    return part;
  };

  boardApi.dot = function (at, drawOptions = {}) {
    const dotPoint = requirePoint(at, 'dot(at): at');
    const dotColor = resolveColor(drawOptions.color, NAMED_COLORS.ink);
    const dotRadius = drawOptions.radius || 5.5;
    const roughGroup = roughSvgPainter.circle(dotPoint[0], dotPoint[1], dotRadius * 2, {
      stroke: dotColor, fill: dotColor, fillStyle: 'solid', roughness: 0.4, strokeWidth: 1.5, seed: Math.floor(Math.random() * 2 ** 31),
    });
    const part = makePart('dot', [addRoughShape(roughGroup)], [dotPoint[0] - dotRadius, dotPoint[1] - dotRadius, dotRadius * 2, dotRadius * 2]);
    part.center = dotPoint;
    if (drawOptions.label != null) boardApi.label(dotPoint, drawOptions.label, { side: drawOptions.side || 'above-right', color: drawOptions.labelColor || drawOptions.color, math: drawOptions.labelMath, size: drawOptions.labelSize });
    return part;
  };

  // label(target, words): target is a point [x, y], a polygon side (tri.side(0)),
  // or any part (labels its box). side: above / below / left / right / above-right ...
  boardApi.label = function (target, words, drawOptions = {}) {
    let anchorPoint;
    let direction;
    if (target && target.outward && target.mid) {
      anchorPoint = target.mid;
      direction = target.outward;
    } else if (target && Array.isArray(target.box)) {
      const sideName = drawOptions.side || 'above';
      direction = SIDE_DIRECTIONS[sideName] || SIDE_DIRECTIONS.above;
      const [boxX, boxY, boxWidth, boxHeight] = target.box;
      anchorPoint = [boxX + boxWidth / 2 + direction[0] * boxWidth / 2, boxY + boxHeight / 2 + direction[1] * boxHeight / 2];
    } else {
      anchorPoint = requirePoint(target, 'label(target, words): target');
      direction = SIDE_DIRECTIONS[drawOptions.side || 'above'] || SIDE_DIRECTIONS.above;
    }
    if (drawOptions.side && SIDE_DIRECTIONS[drawOptions.side] && target && target.outward) direction = SIDE_DIRECTIONS[drawOptions.side];
    const wordsElement = makeWordsElement({ size: drawOptions.math ? 28 : 36, ...drawOptions }, drawOptions.math ? 'clean' : 'hand');
    if (drawOptions.math) fillWithMath(wordsElement, words);
    else wordsElement.textContent = String(words);
    const box = placeWordsAwayFrom(wordsElement, anchorPoint, direction, drawOptions.gap);
    return makeWordsPart('label', wordsElement, box, String(words).length * 14);
  };

  boardApi.rightAngle = function (vertex, towardA, towardB, drawOptions = {}) {
    const cornerPoint = requirePoint(vertex, 'rightAngle(vertex, towardA, towardB): vertex');
    const markSize = drawOptions.size || 18;
    const alongA = scalePoint(unitVector(subtractPoints(requirePoint(towardA, 'rightAngle towardA'), cornerPoint)), markSize);
    const alongB = scalePoint(unitVector(subtractPoints(requirePoint(towardB, 'rightAngle towardB'), cornerPoint)), markSize);
    const markPoints = [addPoints(cornerPoint, alongA), addPoints(addPoints(cornerPoint, alongA), alongB), addPoints(cornerPoint, alongB)];
    const roughGroup = roughSvgPainter.linearPath(markPoints, roughOptions({ width: 2, ...drawOptions }, { roughness: 0.4 }));
    return makePart('rightAngle', [addRoughShape(roughGroup)], boxOfPoints([cornerPoint, ...markPoints]));
  };

  boardApi.angle = function (pointA, vertex, pointB, drawOptions = {}) {
    const cornerPoint = requirePoint(vertex, 'angle(a, vertex, b): vertex');
    const directionA = unitVector(subtractPoints(requirePoint(pointA, 'angle a'), cornerPoint));
    const directionB = unitVector(subtractPoints(requirePoint(pointB, 'angle b'), cornerPoint));
    const arcRadius = drawOptions.radius || 36;
    const arcStart = addPoints(cornerPoint, scalePoint(directionA, arcRadius));
    const arcEnd = addPoints(cornerPoint, scalePoint(directionB, arcRadius));
    // Sweep the short way round: cross product sign says which way that is.
    const crossProduct = directionA[0] * directionB[1] - directionA[1] * directionB[0];
    const sweepFlag = crossProduct > 0 ? 1 : 0;
    const arcPath = `M ${formatPoint(arcStart)} A ${arcRadius} ${arcRadius} 0 0 ${sweepFlag} ${formatPoint(arcEnd)}`;
    const roughGroup = roughSvgPainter.path(arcPath, roughOptions({ width: 2, ...drawOptions }, { roughness: 0.5 }));
    const part = makePart('angle', [addRoughShape(roughGroup)], boxOfPoints([cornerPoint, arcStart, arcEnd]));
    if (drawOptions.label != null) {
      const bisector = unitVector(addPoints(directionA, directionB));
      const labelElement = makeWordsElement({ size: 26, color: drawOptions.labelColor || drawOptions.color }, drawOptions.labelMath ? 'clean' : 'hand');
      if (drawOptions.labelMath) fillWithMath(labelElement, drawOptions.label);
      else labelElement.textContent = String(drawOptions.label);
      placeWordsAwayFrom(labelElement, addPoints(cornerPoint, scalePoint(bisector, arcRadius)), bisector, 4);
      queueWipeReveal(labelElement, 30);
      part.elements.push(labelElement);
    }
    return part;
  };

  // brace(from, to, words): a curly brace bulging to the right of the direction
  // from -> to (so below a left-to-right brace). Swap the points to flip it.
  boardApi.brace = function (from, to, words, drawOptions = {}) {
    const startPoint = requirePoint(from, 'brace(from, to): from');
    const endPoint = requirePoint(to, 'brace(from, to): to');
    const along = unitVector(subtractPoints(endPoint, startPoint));
    const bulge = [-along[1], along[0]];
    const depth = drawOptions.depth || 11;
    const braceMid = midpoint(startPoint, endPoint);
    const pointAt = (basePoint, alongAmount, bulgeAmount) => addPoints(addPoints(basePoint, scalePoint(along, alongAmount)), scalePoint(bulge, bulgeAmount));
    const bracePath = [
      `M ${formatPoint(startPoint)}`,
      `Q ${formatPoint(pointAt(startPoint, 0, depth))} ${formatPoint(pointAt(startPoint, depth, depth))}`,
      `L ${formatPoint(pointAt(braceMid, -depth, depth))}`,
      `Q ${formatPoint(pointAt(braceMid, 0, depth))} ${formatPoint(pointAt(braceMid, 0, depth * 2))}`,
      `Q ${formatPoint(pointAt(braceMid, 0, depth))} ${formatPoint(pointAt(braceMid, depth, depth))}`,
      `L ${formatPoint(pointAt(endPoint, -depth, depth))}`,
      `Q ${formatPoint(pointAt(endPoint, 0, depth))} ${formatPoint(endPoint)}`,
    ].join(' ');
    const roughGroup = roughSvgPainter.path(bracePath, roughOptions({ width: 2.2, ...drawOptions }, { roughness: 0.5 }));
    const part = makePart('brace', [addRoughShape(roughGroup)], boxOfPoints([startPoint, endPoint, pointAt(braceMid, 0, depth * 2)]));
    if (words != null && words !== '') {
      const labelElement = makeWordsElement({ size: 26, color: drawOptions.labelColor || drawOptions.color }, drawOptions.math ? 'clean' : 'hand');
      if (drawOptions.math) fillWithMath(labelElement, words);
      else labelElement.textContent = String(words);
      placeWordsAwayFrom(labelElement, pointAt(braceMid, 0, depth * 2), bulge, 6);
      queueWipeReveal(labelElement, String(words).length * 14);
      part.elements.push(labelElement);
    }
    return part;
  };

  // connect(partA, partB): an arrow from the edge of one part to the edge of another.
  boardApi.connect = function (fromPart, toPart, drawOptions = {}) {
    const fromBox = boxOfTarget(fromPart, 'connect(from, to): from');
    const toBox = boxOfTarget(toPart, 'connect(from, to): to');
    const fromCenter = [fromBox[0] + fromBox[2] / 2, fromBox[1] + fromBox[3] / 2];
    const toCenter = [toBox[0] + toBox[2] / 2, toBox[1] + toBox[3] / 2];
    const startPoint = pointWhereRayLeavesBox(fromCenter, toCenter, fromBox, 8);
    const endPoint = pointWhereRayLeavesBox(toCenter, fromCenter, toBox, 8);
    const connectorPart = boardApi.arrow(startPoint, endPoint, drawOptions);
    // Remembered so erasing either end also erases this arrow, instead of
    // leaving it pointing at nothing.
    connectorPart.connectedParts = [fromPart, toPart];
    return connectorPart;
  };

  function boxOfTarget(target, description) {
    if (target && Array.isArray(target.box)) return target.box;
    if (Array.isArray(target) && target.length === 4 && target.every(value => isFinite(value))) return target;
    if (Array.isArray(target) && target.length === 2) return [target[0], target[1], 0, 0];
    throw new Error(`${description} must be a part (something a draw call returned), a point [x, y] or a box [x, y, w, h]`);
  }

  function pointWhereRayLeavesBox(insidePoint, towardPoint, box, padding) {
    const direction = subtractPoints(towardPoint, insidePoint);
    const halfWidth = box[2] / 2 + padding;
    const halfHeight = box[3] / 2 + padding;
    const scaleToEdge = Math.min(
      Math.abs(direction[0]) < 1e-9 ? Infinity : halfWidth / Math.abs(direction[0]),
      Math.abs(direction[1]) < 1e-9 ? Infinity : halfHeight / Math.abs(direction[1])
    );
    return isFinite(scaleToEdge) ? addPoints(insidePoint, scalePoint(direction, Math.min(scaleToEdge, 1))) : insidePoint;
  }

  boardApi.highlight = function (target, drawOptions = {}) {
    const [boxX, boxY, boxWidth, boxHeight] = boxOfTarget(target, 'highlight(target)');
    const highlightElement = document.createElement('div');
    highlightElement.className = 'board-highlight';
    const highlightColor = resolveColor(drawOptions.color, '#FFD43B');
    highlightElement.style.background = colorWithAlpha(highlightColor, drawOptions.color ? 0.28 : 0.6);
    const padding = drawOptions.padding == null ? 5 : drawOptions.padding;
    highlightElement.style.left = (boxX - padding) + 'px';
    highlightElement.style.top = (boxY - padding) + 'px';
    highlightElement.style.width = (boxWidth + padding * 2) + 'px';
    highlightElement.style.height = (boxHeight + padding * 2) + 'px';
    highlightLayer.appendChild(highlightElement);
    queueWipeReveal(highlightElement, boxWidth * 0.5);
    return makePart('highlight', [highlightElement], [boxX - padding, boxY - padding, boxWidth + padding * 2, boxHeight + padding * 2]);
  };

  // erase(part): fades a part away (the pen doesn't redraw it).
  boardApi.erase = function (part) {
    if (!part || !Array.isArray(part.elements)) throw new Error('erase(part): part must be something a draw call returned');
    for (const element of part.elements) {
      const fadeAnimation = element.animate([{ opacity: 1 }, { opacity: 0 }], { duration: 350, fill: 'forwards' });
      fadeAnimation.onfinish = () => element.remove();
    }
    partsOnBoard = partsOnBoard.filter(existingPart => existingPart !== part);
    const connectorsToErasedPart = partsOnBoard.filter(existingPart =>
      Array.isArray(existingPart.connectedParts) && existingPart.connectedParts.includes(part));
    for (const connectorPart of connectorsToErasedPart) boardApi.erase(connectorPart);
  };

  boardApi.clear = function () {
    finishAllRunningAnimations();
    itemsToRevealInCurrentStep = [];
    inkLayer.replaceChildren();
    wordsLayer.replaceChildren();
    highlightLayer.replaceChildren();
    partsOnBoard = [];
    mostRecentAxes = null;
    for (const savedName of Object.keys(namesSavedBySnippets)) delete namesSavedBySnippets[savedName];
  };

  // ------------------------------------------------------------ graphs

  function niceTickStep(range) {
    const roughStep = range / 8;
    const magnitude = Math.pow(10, Math.floor(Math.log10(roughStep)));
    const normalized = roughStep / magnitude;
    const niceNormalized = normalized < 1.5 ? 1 : normalized < 3 ? 2 : normalized < 7 ? 5 : 10;
    return niceNormalized * magnitude;
  }

  function formatTickNumber(value) {
    const rounded = Math.round(value * 1000) / 1000;
    return String(rounded).replace('-', '−');
  }

  // axes({x: [min, max], y: [min, max], box: [x, y, w, h], labels: {x, y}, ticks, grid})
  // returns a graph: graph.at(x, y) -> board point, graph.plot(fn), graph.point(x, y),
  // graph.shade(top, bottom, from, to), graph.vline(x), graph.hline(y).
  boardApi.axes = function (drawOptions = {}) {
    const xRange = drawOptions.x || [-5, 5];
    const yRange = drawOptions.y || [-5, 5];
    const graphBox = drawOptions.box || [110, 45, 800, 520];
    if (!(xRange[1] > xRange[0]) || !(yRange[1] > yRange[0])) throw new Error('axes: x and y ranges must be [min, max] with max > min');
    const [boxX, boxY, boxWidth, boxHeight] = graphBox;
    const toBoard = (xValue, yValue) => [
      boxX + (xValue - xRange[0]) / (xRange[1] - xRange[0]) * boxWidth,
      boxY + boxHeight - (yValue - yRange[0]) / (yRange[1] - yRange[0]) * boxHeight,
    ];
    const axisColor = resolveColor(drawOptions.color, NAMED_COLORS.ink);
    const xAxisValue = yRange[0] <= 0 && yRange[1] >= 0 ? 0 : yRange[0];
    const yAxisValue = xRange[0] <= 0 && xRange[1] >= 0 ? 0 : xRange[0];
    const axisElements = [];

    if (drawOptions.grid) {
      const gridGroups = [];
      const gridStepX = drawOptions.xStep || niceTickStep(xRange[1] - xRange[0]);
      const gridStepY = drawOptions.yStep || niceTickStep(yRange[1] - yRange[0]);
      for (let gridX = Math.ceil(xRange[0] / gridStepX) * gridStepX; gridX <= xRange[1] + 1e-9; gridX += gridStepX) {
        gridGroups.push(roughSvgPainter.line(...toBoard(gridX, yRange[0]), ...toBoard(gridX, yRange[1]), { stroke: 'rgba(43,45,51,0.12)', strokeWidth: 1, roughness: 0 }));
      }
      for (let gridY = Math.ceil(yRange[0] / gridStepY) * gridStepY; gridY <= yRange[1] + 1e-9; gridY += gridStepY) {
        gridGroups.push(roughSvgPainter.line(...toBoard(xRange[0], gridY), ...toBoard(xRange[1], gridY), { stroke: 'rgba(43,45,51,0.12)', strokeWidth: 1, roughness: 0 }));
      }
      const gridGroup = makeSvgGroup(gridGroups);
      inkLayer.appendChild(gridGroup);
      itemsToRevealInCurrentStep.push({ kind: 'wipe', element: gridGroup, revealWeight: 60 });
      axisElements.push(gridGroup);
    }

    const xAxisPart = drawLineOrArrow(toBoard(xRange[0], xAxisValue), addPoints(toBoard(xRange[1], xAxisValue), [14, 0]), { color: drawOptions.color, width: 2.2, roughness: 0.5 }, true);
    const yAxisPart = drawLineOrArrow(toBoard(yAxisValue, yRange[0]), addPoints(toBoard(yAxisValue, yRange[1]), [0, -14]), { color: drawOptions.color, width: 2.2, roughness: 0.5 }, true);
    partsOnBoard = partsOnBoard.filter(existingPart => existingPart !== xAxisPart && existingPart !== yAxisPart);
    axisElements.push(...xAxisPart.elements, ...yAxisPart.elements);

    if (drawOptions.ticks !== false) {
      const tickStepX = drawOptions.xStep || niceTickStep(xRange[1] - xRange[0]);
      const tickStepY = drawOptions.yStep || niceTickStep(yRange[1] - yRange[0]);
      const tickGroups = [];
      const tickLabelElements = [];
      const addTickLabel = (anchorPoint, value, align, valign) => {
        const tickLabelElement = makeWordsElement({ size: 15, color: 'grey', font: 'clean' }, 'clean');
        tickLabelElement.textContent = formatTickNumber(value);
        placeWordsElement(tickLabelElement, anchorPoint, align, valign);
        tickLabelElements.push(tickLabelElement);
      };
      for (let tickX = Math.ceil(xRange[0] / tickStepX) * tickStepX; tickX <= xRange[1] + 1e-9; tickX += tickStepX) {
        if (Math.abs(tickX - yAxisValue) < 1e-9) continue;
        const tickPoint = toBoard(tickX, xAxisValue);
        tickGroups.push(roughSvgPainter.line(tickPoint[0], tickPoint[1] - 5, tickPoint[0], tickPoint[1] + 5, { stroke: axisColor, strokeWidth: 1.6, roughness: 0 }));
        addTickLabel([tickPoint[0], tickPoint[1] + 9], tickX, 'center', 'top');
      }
      for (let tickY = Math.ceil(yRange[0] / tickStepY) * tickStepY; tickY <= yRange[1] + 1e-9; tickY += tickStepY) {
        if (Math.abs(tickY - xAxisValue) < 1e-9) continue;
        const tickPoint = toBoard(yAxisValue, tickY);
        tickGroups.push(roughSvgPainter.line(tickPoint[0] - 5, tickPoint[1], tickPoint[0] + 5, tickPoint[1], { stroke: axisColor, strokeWidth: 1.6, roughness: 0 }));
        addTickLabel([tickPoint[0] - 10, tickPoint[1]], tickY, 'right', 'middle');
      }
      const tickGroup = makeSvgGroup(tickGroups);
      inkLayer.appendChild(tickGroup);
      const ticksAndLabelsWrapper = { kind: 'wipe', element: tickGroup, revealWeight: 80 };
      itemsToRevealInCurrentStep.push(ticksAndLabelsWrapper);
      tickLabelElements.forEach(tickLabelElement => queueWipeReveal(tickLabelElement, 6));
      axisElements.push(tickGroup, ...tickLabelElements);
    }

    const axisLabels = drawOptions.labels || { x: 'x', y: 'y' };
    if (axisLabels.x) {
      const xLabelElement = makeWordsElement({ size: 28, color: drawOptions.color }, 'hand');
      xLabelElement.textContent = String(axisLabels.x);
      // Under the arrow tip, right-aligned, so a long label never runs off the board.
      placeWordsElement(xLabelElement, addPoints(toBoard(xRange[1], xAxisValue), [14, 28]), 'right', 'top');
      queueWipeReveal(xLabelElement, 20);
      axisElements.push(xLabelElement);
    }
    if (axisLabels.y) {
      const yLabelElement = makeWordsElement({ size: 28, color: drawOptions.color }, 'hand');
      yLabelElement.textContent = String(axisLabels.y);
      placeWordsElement(yLabelElement, addPoints(toBoard(yAxisValue, yRange[1]), [0, -20]), 'center', 'bottom');
      queueWipeReveal(yLabelElement, 20);
      axisElements.push(yLabelElement);
    }

    const graph = makePart('axes', axisElements, graphBox);
    graph.x = xRange;
    graph.y = yRange;
    graph.at = (xValue, yValue) => toBoard(xValue, yValue);

    // plot(fn, {from, to, color, label, dashed}): draws y = fn(x), breaking the
    // line where the function leaves the visible range or isn't defined.
    graph.plot = (plottedFunction, plotOptions = {}) => {
      if (typeof plottedFunction !== 'function') throw new Error('plot(fn): fn must be a function like x => x * x');
      const fromX = plotOptions.from == null ? xRange[0] : plotOptions.from;
      const toX = plotOptions.to == null ? xRange[1] : plotOptions.to;
      const sampleCount = 260;
      const yMargin = (yRange[1] - yRange[0]) * 0.02;
      const segments = [];
      let currentSegment = [];
      for (let sampleIndex = 0; sampleIndex <= sampleCount; sampleIndex++) {
        const xValue = fromX + (toX - fromX) * sampleIndex / sampleCount;
        let yValue;
        try { yValue = plottedFunction(xValue); } catch (functionError) { yValue = NaN; }
        const isVisible = isFinite(yValue) && yValue >= yRange[0] - yMargin && yValue <= yRange[1] + yMargin;
        if (isVisible) {
          currentSegment.push(toBoard(xValue, yValue));
        } else if (currentSegment.length) {
          segments.push(currentSegment);
          currentSegment = [];
        }
      }
      if (currentSegment.length) segments.push(currentSegment);
      const drawableSegments = segments.filter(segment => segment.length >= 2);
      if (drawableSegments.length === 0) throw new Error('plot(fn): the function never appears inside the axes ranges');
      const plotColor = plotOptions.color || 'accent';
      const segmentGroups = drawableSegments.map(segment => roughSvgPainter.linearPath(segment, roughOptions({ width: 3, ...plotOptions, color: plotColor }, { roughness: plotOptions.roughness == null ? 0.35 : plotOptions.roughness, bowing: 0 })));
      const plotGroup = addRoughShape(makeSvgGroup(segmentGroups));
      const allPlotPoints = drawableSegments.flat();
      const plotPart = makePart('plot', [plotGroup], boxOfPoints(allPlotPoints));
      plotPart.fn = plottedFunction;
      if (plotOptions.label != null) {
        const labelX = plotOptions.labelAt == null ? null : plotOptions.labelAt;
        // By default the label sits 80% of the way along the last visible stretch,
        // away from the board edge where the curve usually leaves the axes.
        const lastSegment = drawableSegments[drawableSegments.length - 1];
        let labelAnchor = lastSegment[Math.floor((lastSegment.length - 1) * 0.8)];
        if (labelX != null && isFinite(plottedFunction(labelX))) labelAnchor = toBoard(labelX, plottedFunction(labelX));
        const labelElement = makeWordsElement({ size: 30, color: plotColor }, plotOptions.labelMath ? 'clean' : 'hand');
        if (plotOptions.labelMath) fillWithMath(labelElement, plotOptions.label);
        else labelElement.textContent = String(plotOptions.label);
        placeWordsAwayFrom(labelElement, labelAnchor, SIDE_DIRECTIONS[plotOptions.labelSide || 'left'], 10);
        queueWipeReveal(labelElement, 30);
        plotPart.elements.push(labelElement);
      }
      return plotPart;
    };

    // point(x, y, {label, guides, color}): a dot at a graph coordinate; guides
    // draws dashed lines down and across to the axes.
    graph.point = (xValue, yValue, pointOptions = {}) => {
      const boardPoint = toBoard(xValue, yValue);
      if (pointOptions.guides) {
        drawLineOrArrow(boardPoint, toBoard(xValue, xAxisValue), { dashed: true, width: 1.6, color: 'grey', roughness: 0.3 }, false);
        drawLineOrArrow(boardPoint, toBoard(yAxisValue, yValue), { dashed: true, width: 1.6, color: 'grey', roughness: 0.3 }, false);
      }
      return boardApi.dot(boardPoint, { color: pointOptions.color || 'accent', ...pointOptions });
    };

    // shade(top, bottom, from, to): fills the area between two functions (or
    // numbers) from x = from to x = to.
    graph.shade = (topBoundary, bottomBoundary, fromX, toX, shadeOptions = {}) => {
      const valueOf = (boundary, xValue) => (typeof boundary === 'function' ? boundary(xValue) : Number(boundary));
      const sampleCount = 80;
      const outlinePoints = [];
      for (let sampleIndex = 0; sampleIndex <= sampleCount; sampleIndex++) {
        const xValue = fromX + (toX - fromX) * sampleIndex / sampleCount;
        outlinePoints.push(toBoard(xValue, Math.min(yRange[1], Math.max(yRange[0], valueOf(topBoundary, xValue)))));
      }
      for (let sampleIndex = sampleCount; sampleIndex >= 0; sampleIndex--) {
        const xValue = fromX + (toX - fromX) * sampleIndex / sampleCount;
        outlinePoints.push(toBoard(xValue, Math.min(yRange[1], Math.max(yRange[0], valueOf(bottomBoundary, xValue)))));
      }
      const shadeColor = resolveColor(shadeOptions.color, NAMED_COLORS.accent);
      const roughGroup = roughSvgPainter.polygon(outlinePoints, {
        stroke: 'none', fill: colorWithAlpha(shadeColor, 0.55), fillStyle: shadeOptions.fillStyle || 'hachure',
        hachureGap: 8, fillWeight: 1.4, roughness: 0.8, seed: Math.floor(Math.random() * 2 ** 31),
      });
      return makePart('shade', [addRoughShape(roughGroup)], boxOfPoints(outlinePoints));
    };

    graph.vline = (xValue, lineOptions = {}) => drawLineOrArrow(toBoard(xValue, yRange[0]), toBoard(xValue, yRange[1]), { dashed: true, width: 1.8, color: 'grey', roughness: 0.3, ...lineOptions }, false);
    graph.hline = (yValue, lineOptions = {}) => drawLineOrArrow(toBoard(xRange[0], yValue), toBoard(xRange[1], yValue), { dashed: true, width: 1.8, color: 'grey', roughness: 0.3, ...lineOptions }, false);

    mostRecentAxes = graph;
    return graph;
  };

  // plot(fn) without a graph uses the most recent axes, drawing default ones first if needed.
  boardApi.plot = function (plottedFunction, plotOptions = {}) {
    if (!mostRecentAxes) boardApi.axes();
    return mostRecentAxes.plot(plottedFunction, plotOptions);
  };

  // Small geometry helpers for laying things out.
  boardApi.mid = (pointA, pointB) => midpoint(requirePoint(pointA, 'mid(a, b): a'), requirePoint(pointB, 'mid(a, b): b'));
  boardApi.lerp = (pointA, pointB, fraction) => addPoints(pointA, scalePoint(subtractPoints(pointB, pointA), fraction));
  boardApi.polar = (center, radius, degrees) => {
    const radians = degrees * Math.PI / 180;
    return [center[0] + radius * Math.cos(radians), center[1] - radius * Math.sin(radians)];
  };
  boardApi.W = BOARD_WIDTH;
  boardApi.H = BOARD_HEIGHT;

  // ------------------------------------------------------------ running Claude's snippets

  // Names a snippet assigns (without let/const) are kept here, so later snippets
  // on the same board can use them. Reads fall back to the API, then to
  // ordinary globals like Math.
  const namesSavedBySnippets = Object.create(null);
  const snippetScope = new Proxy(namesSavedBySnippets, {
    has: () => true,
    get: (savedNames, propertyName) => {
      if (propertyName === Symbol.unscopables) return undefined;
      if (propertyName in savedNames) return savedNames[propertyName];
      if (propertyName in boardApi) return boardApi[propertyName];
      if (propertyName in window) return window[propertyName];
      throw new ReferenceError(`${String(propertyName)} is not defined`);
    },
    set: (savedNames, propertyName, value) => {
      savedNames[propertyName] = value;
      return true;
    },
  });

  function postToApp(message) {
    try { window.webkit.messageHandlers.clickyBoard.postMessage(message); } catch (postError) { /* running in a plain browser */ }
  }

  window.clickyBoard = {
    // Runs one snippet and reveals what it drew over durationSeconds.
    runStep(snippetCode, durationSeconds) {
      finishAllRunningAnimations();
      itemsToRevealInCurrentStep = [];
      let errorMessage = null;
      try {
        // eslint-disable-next-line no-new-func
        const snippetFunction = new Function('snippetScope', 'with (snippetScope) {\n' + snippetCode + '\n}');
        snippetFunction(snippetScope);
      } catch (snippetError) {
        errorMessage = (snippetError && snippetError.message) ? `${snippetError.name}: ${snippetError.message}` : String(snippetError);
      }
      const itemsDrawn = itemsToRevealInCurrentStep.length;
      revealQueuedItems(durationSeconds);
      return { ok: errorMessage === null, error: errorMessage, itemsDrawn, partsOnBoard: partsOnBoard.length };
    },

    newBoard(options = {}) {
      boardApi.clear();
      document.body.classList.toggle('plain-paper', options.paper === 'plain');
    },

    // Jumps every running stroke to its end (before a snapshot, or a barge-in).
    finishNow() {
      finishAllRunningAnimations();
    },
  };

  // Load the fonts before telling the app the board is ready, so text measures
  // correctly the first time it's drawn.
  const fontsToPreload = ['32px ClickyHand', '28px KaTeX_Main', 'italic 28px KaTeX_Math'];
  Promise.all(fontsToPreload.map(fontDescription => document.fonts.load(fontDescription)))
    .catch(() => {})
    .then(() => postToApp({ type: 'ready' }));
})();
