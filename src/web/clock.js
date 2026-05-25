(function() {
  const KST_OFFSET_MS = 9 * 60 * 60 * 1000;
  // 수강신청 등 "절대 빠르면 안 되는" 용도용 안전 마진.
  // 표시 시각 = 추정 서버 시각 - 안전마진. 항상 실제보다 늦게 표시된다.
  // RTT 비대칭(업로드 정체)이 표시를 빠르게 밀 수 있는데 그 위험은 RTT에 비례하므로,
  // 마진도 max(고정 30ms, RTT×0.3)로 적응시킨다. RTT 90ms→30, 200ms→60, 400ms→120.
  const SAFETY_FLOOR_MS = 30;
  const SAFETY_RTT_FRACTION = 0.3;
  const SVG_NS = 'http://www.w3.org/2000/svg';

  const ticksGroup = document.getElementById('ticks');
  const tickEls = [];
  for (let i = 0; i < 12; i++) {
    const angle = (i * 30 - 90) * Math.PI / 180;
    const cx = 100 + 80 * Math.cos(angle);
    const cy = 100 + 80 * Math.sin(angle);
    const c = document.createElementNS(SVG_NS, 'circle');
    c.setAttribute('cx', cx.toFixed(2));
    c.setAttribute('cy', cy.toFixed(2));
    c.setAttribute('r', 2.4);
    c.setAttribute('class', 'tick');
    ticksGroup.appendChild(c);
    tickEls.push(c);
  }

  const handGroup = document.getElementById('hand-group');
  const progressEl = document.getElementById('progress');
  const CIRC = 2 * Math.PI * 92;

  let baseServerMs = null;
  let basePerfMs = null;
  let state = null;
  let lastLitCount = -1;
  let slewRemainingMs = 0;
  let lastRenderPerfMs = null;
  let localReloadRemeasure = false;
  let localFastMeasure = false;
  let activeTargetUrl = null;
  let activeMeasurementUrl = null;
  let activeMeasureRequestAt = null;
  let appliedMeasureAt = null;

  const targetForm = document.getElementById('target-form');
  const targetInput = document.getElementById('target-url');
  const remeasureButton = document.getElementById('remeasure-button');
  const fastMeasureButton = document.getElementById('fast-measure-button');
  const durationHint = document.getElementById('duration-hint');
  const CAP_HINT = '측정 최대 20초 · 재측정 최대 15초 · 빠른 측정 최대 5초';

  function setStatusText(text, warn, prominent) {
    const st = document.getElementById('status');
    st.classList.toggle('warn', !!warn);
    st.classList.toggle('prominent', !!prominent);
    st.textContent = text;
  }

  function setClockBase(serverMs, perfMs) {
    if (baseServerMs == null) {
      baseServerMs = serverMs;
      basePerfMs = perfMs;
      slewRemainingMs = 0;
      return;
    }

    const currentEstimate = nowEstimateMs();
    const diff = serverMs - currentEstimate;
    baseServerMs = currentEstimate;
    basePerfMs = perfMs;

    if (Math.abs(diff) > 120) {
      baseServerMs = serverMs;
      slewRemainingMs = 0;
    } else {
      slewRemainingMs += diff;
    }
  }

  function resetClockBase() {
    baseServerMs = null;
    basePerfMs = null;
    slewRemainingMs = 0;
    lastRenderPerfMs = null;
    appliedMeasureAt = null;
  }

  async function submitTarget(url) {
    const button = targetForm.querySelector('button');
    button.disabled = true;
    remeasureButton.disabled = true;
    setDurationHint('초기 측정: 기본 구간 약 6초, 최대 20초');
    setStatusText('측정 요청 중...', false, true);
    try {
      const res = await fetch('/api/target', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url })
      });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || 'URL 설정 실패');
      const nextTargetUrl = data.targetUrl || '';
      activeTargetUrl = nextTargetUrl;
      targetInput.value = activeTargetUrl;
      resetClockBase();
      localReloadRemeasure = false;
      setStatusText('초기 측정 중... (20초 이내)', false, true);
      await fetchState();
    } catch (e) {
      setStatusText(e.message || 'URL 설정 실패', true, true);
    } finally {
      button.disabled = false;
      updateControls();
    }
  }

  targetForm.addEventListener('submit', function(e) {
    e.preventDefault();
    submitTarget(targetInput.value);
  });

  async function requestRemeasure() {
    if (!state || !state.lastMeasureAt || state.status === 'measuring' || state.status === 'queued') return;
    remeasureButton.disabled = true;
    setDurationHint(CAP_HINT);
    setStatusText('재측정 요청 중...', false, true);
    resetClockBase();
    localReloadRemeasure = true;
    try {
      const res = await fetch('/api/remeasure', { method: 'POST', cache: 'no-store' });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || '재측정 요청 실패');
      await fetchState();
    } catch (e) {
      setStatusText(e.message || '재측정 요청 실패', true, true);
    } finally {
      updateControls();
    }
  }

  remeasureButton.addEventListener('click', requestRemeasure);

  async function requestFastMeasure() {
    if (!state || !state.targetUrl || state.status === 'measuring' || state.status === 'queued') return;
    // 최근(5분 이내) 유효 측정이 있으면 저정확도 결과로 덮어쓰기 전에 확인.
    const recent = state.lastMeasureAt && state.status !== 'stale';
    if (recent && !window.confirm('최근 측정값이 있습니다. 빠른 측정(정확도 낮음)으로 덮어쓸까요?')) return;
    fastMeasureButton.disabled = true;
    setStatusText('빠른 측정 요청 중...', false, true);
    resetClockBase();
    localFastMeasure = true;
    try {
      const res = await fetch('/api/measure-fast', { method: 'POST', cache: 'no-store' });
      const data = await res.json();
      if (!res.ok || !data.ok) throw new Error(data.error || '빠른 측정 요청 실패');
      await fetchState();
    } catch (e) {
      localFastMeasure = false;
      setStatusText(e.message || '빠른 측정 요청 실패', true, true);
    } finally {
      updateControls();
    }
  }

  fastMeasureButton.addEventListener('click', requestFastMeasure);

  function setDurationHint(text) {
    durationHint.textContent = text;
  }

  function updateControls() {
    const isBusy = !!state && (state.status === 'measuring' || state.status === 'queued');
    const hasMeasuredTarget = !!state && !!state.targetUrl && !!state.lastMeasureAt;
    const hasTarget = !!state && !!state.targetUrl;
    remeasureButton.disabled = isBusy || !hasMeasuredTarget;
    // 빠른 측정은 첫 측정으로도 쓸 수 있어 targetUrl만 있으면 활성.
    if (fastMeasureButton) fastMeasureButton.disabled = isBusy || !hasTarget;
    setDurationHint(CAP_HINT);
  }

  async function fetchState() {
    try {
      const t0 = performance.now();
      const res = await fetch('/api/state', { cache: 'no-store' });
      const data = await res.json();
      const t1 = performance.now();
      const lag = (t1 - t0) / 2;
      // /api/state는 같은 PC의 로컬 서버라 정상 왕복은 수 ms다.
      // 그러나 측정 중에는 단일 스레드 PowerShell HTTP 서버가 측정 루프에 막혀,
      // 진행 중이던 /api/state가 측정이 끝날 때(~10초)까지 반환되지 않는다.
      // 그러면 (t1-t0)/2가 ~5000ms로 튀고, serverAtFetch가 +5초 미래로 계산되어
      // hasLargeDisplayDrift가 켜지면 기존값 유지(measureAt 불변) 재측정인데도
      // 기준점이 +5초로 갱신됐다가 다음 정상 폴에서 되돌아온다(=순간 흔들림).
      // 비정상적으로 큰 lag는 신뢰할 수 없으므로 이 응답으로는 기준점을 갱신하지 않는다.
      const lagTrustworthy = lag <= 300;

      const nextTargetUrl = data.targetUrl || '';
      const nextMeasurementUrl = data.measurementUrl || '';
      if (activeTargetUrl === null) {
        activeTargetUrl = nextTargetUrl;
        activeMeasurementUrl = nextMeasurementUrl;
        targetInput.value = activeTargetUrl;
      } else if (nextTargetUrl !== activeTargetUrl || nextMeasurementUrl !== activeMeasurementUrl) {
        activeTargetUrl = nextTargetUrl;
        activeMeasurementUrl = nextMeasurementUrl;
        targetInput.value = activeTargetUrl;
        resetClockBase();
      }
      const requestAt = data.lastMeasureRequestedAt || null;
      if (requestAt && requestAt !== activeMeasureRequestAt) {
        activeMeasureRequestAt = requestAt;
        if (!data.lastMeasureAt || new Date(requestAt).getTime() > new Date(data.lastMeasureAt).getTime()) {
          resetClockBase();
        }
      }
      // 시계 기준점은 최초 표시 또는 실제 반영된 측정(lastMeasureAt 변경) 때만 갱신.
      // ok 응답마다 재기준화하면 response latency 변동이 초침 점프로 보이고,
      // kept-small-delta/rejected처럼 "기존값 유지"인 재측정도 순간 변화처럼 보인다.
      // 단, baseServerMs가 아직 없는 경우 (F5 직후 등) F5 재측정 동안에도
      // 이전 offsetMs로 일단 시계를 띄워둠. 재측정 끝나면 ok 상태에서 갱신.
      const hasOffsetData = typeof data.offsetMs === 'number' && typeof data.pcSendTimeAtMs === 'number';
      const measureAt = data.lastMeasureAt || null;
      const hasNewAppliedMeasure = !!measureAt && measureAt !== appliedMeasureAt;
      const serverAtFetch = hasOffsetData ? data.pcSendTimeAtMs + data.offsetMs + lag : null;
      const currentEstimate = nowEstimateMs();
      const hasLargeDisplayDrift = lagTrustworthy &&
                                   (data.status === 'ok' || data.status === 'stale') &&
                                   serverAtFetch != null &&
                                   currentEstimate != null &&
                                   Math.abs(serverAtFetch - currentEstimate) > 500;
      const shouldUpdateBase = ((data.status === 'ok' || data.status === 'stale') && hasNewAppliedMeasure) ||
                               hasLargeDisplayDrift ||
                               (baseServerMs == null && hasOffsetData && measureAt);
      if (shouldUpdateBase && hasOffsetData && lagTrustworthy) {
        setClockBase(serverAtFetch, t1);
        appliedMeasureAt = measureAt;
      }
      state = data;
      updateControls();
      if (data.lastMeasureRequestedAt && data.lastMeasureAt &&
          new Date(data.lastMeasureAt).getTime() >= new Date(data.lastMeasureRequestedAt).getTime()) {
        localReloadRemeasure = false;
        localFastMeasure = false;
      } else if (data.lastMeasureRequestedAt && data.lastRemeasureFinishedAt &&
          new Date(data.lastRemeasureFinishedAt).getTime() >= new Date(data.lastMeasureRequestedAt).getTime()) {
        localReloadRemeasure = false;
        localFastMeasure = false;
      }
    } catch (e) {
      console.warn('fetchState failed', e);
    }
  }

  // RTT에 비례하는 적응형 안전마진(ms). state.rttMedianMs가 아직 없으면 floor만.
  function currentSafetyMs() {
    const rtt = (state && typeof state.rttMedianMs === 'number') ? state.rttMedianMs : 0;
    return Math.max(SAFETY_FLOOR_MS, rtt * SAFETY_RTT_FRACTION);
  }

  // 측정에 실제로 쓰인 추정 방법을 사람이 읽을 라벨로.
  // 주의: edge-intersect는 edge들이 "서로" 모순 없다는 뜻이지 "정확하다"는 보장이 아니다.
  // RTT 비대칭은 모든 edge를 같은 방향으로 밀어 상호 일치를 유지한 채 집단 편향을 만든다
  // → 교집합으로는 못 잡는다. 그래서 ✓ 같은 "성공" 표시를 쓰지 않는다.
  function methodLabel(method, edgeCount, acceptedCount) {
    const ec = edgeCount || 0;
    const ac = acceptedCount || 0;
    switch (method) {
      case 'edge-intersect':
        return `교집합 (edge ${ec}개 상호 일치)`;
      case 'edge-intersect-robust':
        return `교집합 (이상치 ${Math.max(0, ec - ac)}개 제외, edge ${ac}/${ec}개)`;
      case 'edge-median':
        return `중앙값 폴백 (edge ${ec}개 상호 불일치)`;
      case 'upper-envelope':
        return '상한봉투 폴백 (edge 미검출)';
      case 'naver-time-api':
        return '네이버 시계 API (ms 정밀)';
      default:
        return method || '?';
    }
  }

  function nowEstimateMs() {
    if (baseServerMs == null) return null;
    return baseServerMs + (performance.now() - basePerfMs);
  }

  function hasPendingRemeasure() {
    if (!state || !state.lastMeasureRequestedAt) return false;
    if (!state.lastMeasureAt) return false;
    const reqT = new Date(state.lastMeasureRequestedAt).getTime();
    // 요청이 이미 끝났으면(반영/유지/거부/실패 무관) 더 이상 pending 아님.
    // 이게 없으면 실패·기존값유지처럼 lastMeasureAt이 안 바뀐 경우 영원히 pending으로 남아
    // "재측정 요청됨..."에서 멈춘다.
    if (state.lastRemeasureFinishedAt && new Date(state.lastRemeasureFinishedAt).getTime() >= reqT) return false;
    return reqT > new Date(state.lastMeasureAt).getTime();
  }

  function isRemeasureUiActive() {
    return !!(localReloadRemeasure || hasPendingRemeasure());
  }

  function activeMeasureLabel() {
    if (localFastMeasure) return '빠른 측정 중... (최대 5초)';
    return isRemeasureUiActive() ? '재측정 중... (15초 이내)' : '초기 측정 중... (20초 이내)';
  }

  function render() {
    const perfNow = performance.now();
    if (baseServerMs != null && lastRenderPerfMs != null && Math.abs(slewRemainingMs) > 0.001) {
      const elapsedMs = Math.max(0, perfNow - lastRenderPerfMs);
      const step = Math.sign(slewRemainingMs) * Math.min(Math.abs(slewRemainingMs), elapsedMs * 0.08);
      baseServerMs += step;
      slewRemainingMs -= step;
    }
    lastRenderPerfMs = perfNow;

    const estimateMs = nowEstimateMs();
    const safetyMs = currentSafetyMs();
    const ms = estimateMs == null ? null : estimateMs - safetyMs;
    if (ms == null) {
      if (state) document.getElementById('host').textContent = state.host || 'URL을 입력하세요';
      document.getElementById('stats').textContent = '';
      document.getElementById('ntp').textContent = '';
      if (!state || state.status === 'idle') {
        setStatusText('측정할 URL을 입력하세요', false, true);
      } else if (state.status === 'queued') {
        setStatusText(activeMeasureLabel(), false, true);
      } else if (state.status === 'measuring') {
        setStatusText(activeMeasureLabel(), false, true);
      } else if (state.status === 'failed') {
        setStatusText('측정 실패 (URL 확인 후 재시도)', true, true);
      }
      return;
    }
    const kst = new Date(ms + KST_OFFSET_MS);

    const hh = String(kst.getUTCHours()).padStart(2, '0');
    const mm = String(kst.getUTCMinutes()).padStart(2, '0');
    const ss = String(kst.getUTCSeconds()).padStart(2, '0');
    const yyyy = kst.getUTCFullYear();
    const mo = kst.getUTCMonth() + 1;
    const d = kst.getUTCDate();
    const dayKr = ['일','월','화','수','목','금','토'][kst.getUTCDay()];

    document.getElementById('hhmm').textContent = `${hh}:${mm}`;
    document.getElementById('sec').textContent = `:${ss}`;
    document.getElementById('date').textContent = `${yyyy}.${mo}.${d}. ${dayKr}요일`;

    if (state) document.getElementById('host').textContent = state.host || '서버 시계';

    const msInMinute = (kst.getUTCSeconds() * 1000) + kst.getUTCMilliseconds();
    const progress = msInMinute / 60000;
    const angleDeg = progress * 360;
    handGroup.setAttribute('transform', `rotate(${angleDeg.toFixed(3)} 100 100)`);
    progressEl.setAttribute('stroke-dashoffset', (CIRC * (1 - progress)).toFixed(2));

    const litCount = Math.floor(kst.getUTCSeconds() / 5) + 1;
    if (litCount !== lastLitCount) {
      for (let i = 0; i < 12; i++) {
        if (i < litCount) tickEls[i].classList.add('lit');
        else tickEls[i].classList.remove('lit');
      }
      lastLitCount = litCount;
    }

    if (!state) return;

    const ago = state.lastMeasureAt
      ? Math.round((Date.now() - new Date(state.lastMeasureAt).getTime()) / 1000)
      : '-';
    const sampleCount = state.sampleCount || 0;
    const acceptedCount = state.acceptedCount || 0;
    let label = methodLabel(state.method, state.edgeCount, acceptedCount);
    if (state.lastMeasureMode === 'fast') label = '⚡ 빠른 측정 · ' + label + ' (정확도 낮음)';
    const measurementNote = state.measurementNote === 'interpark-final-ticket-page'
      ? '  측정경로: nol.interpark.com/ticket'
      : '';
    // 교집합 계열의 ±는 "일치 폭"(feasible 영역 반폭)이지 정확도 보장이 아니다.
    // RTT 비대칭 같은 공통 편향은 이 폭에 안 잡힘 → '일치폭'으로 명시.
    const isIntersect = (state.method || '').indexOf('edge-intersect') === 0;
    const spreadLabel = isIntersect
      ? `일치폭 ±${Math.round(state.ci95Ms || 0)}ms(비대칭 미반영)`
      : `±${Math.round(state.ci95Ms || 0)}ms`;
    document.getElementById('stats').textContent =
      `측정: ${ago}초 전  RTT ${Math.round(state.rttMedianMs || 0)}ms  ${spreadLabel}  샘플 ${sampleCount}개  방법: ${label}  안전마진 -${Math.round(safetyMs)}ms${measurementNote}`;

    const ntp = document.getElementById('ntp');
    if (state.ntpInfo) {
      const sign = state.ntpInfo.skewMs >= 0 ? '+' : '';
      ntp.textContent = `참고: PC 시계 ${sign}${Math.round(state.ntpInfo.skewMs)}ms`;
    } else {
      ntp.textContent = '';
    }

    if (state.status === 'failed') {
      setStatusText('측정 실패 (새로고침으로 재시도)', true, false);
    } else if (state.status === 'stale') {
      setStatusText('오프셋 오래됨', true, false);
    } else if (state.status === 'idle') {
      setStatusText('측정할 URL을 입력하세요', false, true);
    } else if (state.status === 'queued') {
      setStatusText(activeMeasureLabel(), false, true);
    } else if (state.status === 'measuring') {
      setStatusText(activeMeasureLabel(), false, isRemeasureUiActive());
    } else if (state.lastRemeasureResult === 'fast') {
      setStatusText('⚡ 빠른 측정 완료 (정확도 낮음)', false, true);
    } else if (state.lastRemeasureResult === 'failed') {
      setStatusText('측정 실패: 기존값 유지', true, true);
    } else if (state.lastRemeasureResult === 'failed-insufficient-edges') {
      setStatusText('재측정 실패 (edge 부족): 기존값 유지', true, true);
    } else if (state.lastRemeasureResult === 'rejected') {
      const delta = Math.round(state.lastRemeasureDeltaMs || 0);
      setStatusText(`재측정 편차 ${delta}ms 초과: 기존값 유지`, true, true);
    } else if (state.lastRemeasureResult === 'kept-small-delta') {
      const delta = Math.round(state.lastRemeasureDeltaMs || 0);
      setStatusText(`재측정 차이 ${delta}ms: 기존값 유지`, false, true);
    } else if (state.lastRemeasureResult === 'accepted' && state.lastRemeasureAttempts > 1) {
      setStatusText('재측정 완료 (2회차 반영)', false, true);
    } else if (localFastMeasure) {
      setStatusText('빠른 측정 요청됨...', false, true);
    } else if (hasPendingRemeasure() || localReloadRemeasure) {
      setStatusText(localReloadRemeasure ? '새로고침중... 재측정 확인 중' : '재측정 요청됨...', false, true);
    } else {
      setStatusText('', false, false);
    }
  }

  function loop() {
    render();
    requestAnimationFrame(loop);
  }

  // ===== 측정 상세 시각화 =====
  const detailsToggle = document.getElementById('details-toggle');
  const detailsEl = document.getElementById('details');
  const detailsSummary = document.getElementById('details-summary');
  const timelineEl = document.getElementById('timeline');
  const tooltipEl = document.getElementById('details-tooltip');
  let detailsOpen = false;
  let lastSamplesData = null;
  let lastRenderedAt = null;
  let lastRenderedRemeasureAt = null;

  detailsToggle.addEventListener('click', async function() {
    detailsOpen = !detailsOpen;
    detailsToggle.classList.toggle('active', detailsOpen);
    detailsToggle.textContent = detailsOpen ? '측정 상세 닫기' : '측정 상세 보기';
    detailsEl.hidden = !detailsOpen;
    if (detailsOpen) await refreshDetails();
  });

  async function refreshDetails() {
    try {
      const res = await fetch('/api/samples', { cache: 'no-store' });
      const data = await res.json();
      lastSamplesData = data;
      renderTimeline(data);
    } catch (e) {
      detailsSummary.textContent = '샘플 데이터 로드 실패: ' + e.message;
    }
  }

  function renderTimeline(data) {
    while (timelineEl.firstChild) timelineEl.removeChild(timelineEl.firstChild);
    if (!data || !data.samples || data.samples.length < 2) {
      detailsSummary.textContent = '아직 측정 결과가 없습니다.';
      return;
    }
    const originalSamples = data.samples.map((s, idx) => ({
      ...s,
      idx,
      serverEventPcMs: s.pcAtT2Ms - (s.rttMs / 2)
    }));
    const samples = originalSamples.slice().sort((a, b) => a.serverEventPcMs - b.serverEventPcMs);
    const edges = data.edges || [];

    const edgeTimes = edges.map(e => e.edgePcMs).filter(ms => typeof ms === 'number');
    const t0 = Math.min(samples[0].serverEventPcMs, ...edgeTimes);
    const tEnd = Math.max(samples[samples.length - 1].serverEventPcMs, ...edgeTimes);
    const totalMs = Math.max(1, tEnd - t0);
    const rttMedian = data.rttMedianMs || 0;
    const rttThreshold = Math.max(rttMedian * 2, rttMedian + 50);

    const W = 720, H = 200;
    const margin = { left: 50, right: 20, top: 30, bottom: 40 };
    const innerW = W - margin.left - margin.right;
    const innerH = H - margin.top - margin.bottom;
    const xScale = ms => margin.left + ((ms - t0) / totalMs) * innerW;
    const yMid = margin.top + innerH * 0.55;

    // Date second 모듈로 색깔/y 위치 분기
    const dateSec = s => Math.floor(s.serverDateMs / 1000);

    // 서버 처리 추정 시각 기준의 큰 간격 음영 표시
    for (let i = 1; i < samples.length; i++) {
      const gap = samples[i].serverEventPcMs - samples[i-1].serverEventPcMs;
      const expectedGap = Math.max(rttMedian + 50, 110);
      if (gap > expectedGap * 3) {
        const band = document.createElementNS(SVG_NS, 'rect');
        band.setAttribute('class', 'gap-band');
        band.setAttribute('x', xScale(samples[i-1].serverEventPcMs).toFixed(1));
        band.setAttribute('y', margin.top);
        band.setAttribute('width', (xScale(samples[i].serverEventPcMs) - xScale(samples[i-1].serverEventPcMs)).toFixed(1));
        band.setAttribute('height', innerH);
        timelineEl.appendChild(band);
      }
    }

    // 축
    const axisLine = document.createElementNS(SVG_NS, 'line');
    axisLine.setAttribute('class', 'axis');
    axisLine.setAttribute('x1', margin.left);
    axisLine.setAttribute('y1', H - margin.bottom);
    axisLine.setAttribute('x2', W - margin.right);
    axisLine.setAttribute('y2', H - margin.bottom);
    timelineEl.appendChild(axisLine);

    // X축 눈금 (1초 간격)
    const tickInterval = totalMs > 20000 ? 5000 : (totalMs > 8000 ? 2000 : 1000);
    for (let t = 0; t <= totalMs; t += tickInterval) {
      const x = xScale(t0 + t);
      const tick = document.createElementNS(SVG_NS, 'line');
      tick.setAttribute('class', 'axis');
      tick.setAttribute('x1', x); tick.setAttribute('x2', x);
      tick.setAttribute('y1', H - margin.bottom);
      tick.setAttribute('y2', H - margin.bottom + 5);
      timelineEl.appendChild(tick);
      const label = document.createElementNS(SVG_NS, 'text');
      label.setAttribute('class', 'axis-label');
      label.setAttribute('x', x);
      label.setAttribute('y', H - margin.bottom + 18);
      label.setAttribute('text-anchor', 'middle');
      label.textContent = (t / 1000).toFixed(t >= 1000 ? 0 : 1) + 's';
      timelineEl.appendChild(label);
    }

    // 제목 라벨
    const titleX = document.createElementNS(SVG_NS, 'text');
    titleX.setAttribute('class', 'axis-label');
    titleX.setAttribute('x', W / 2);
    titleX.setAttribute('y', H - 5);
    titleX.setAttribute('text-anchor', 'middle');
    titleX.textContent = '측정 시작 후 경과 시간 (서버 처리 추정 시각 기준: t2 - RTT/2)';
    timelineEl.appendChild(titleX);

    // Edge 마커 (샘플보다 먼저 그려서 점이 위에 오도록)
    edges.forEach(e => {
      const prev = originalSamples[e.prevIdx];
      const curr = originalSamples[e.currIdx];
      if (!prev || !curr) return;
      const xEdge = xScale(e.edgePcMs);
      const line = document.createElementNS(SVG_NS, 'line');
      line.setAttribute('class', 'edge-line');
      line.setAttribute('x1', xEdge); line.setAttribute('x2', xEdge);
      line.setAttribute('y1', margin.top + 10);
      line.setAttribute('y2', H - margin.bottom);
      timelineEl.appendChild(line);

      const tri = document.createElementNS(SVG_NS, 'polygon');
      tri.setAttribute('class', 'edge-tick');
      tri.setAttribute('points', `${xEdge-4},${margin.top+5} ${xEdge+4},${margin.top+5} ${xEdge},${margin.top+11}`);
      timelineEl.appendChild(tri);
    });

    // 샘플 점들
    samples.forEach(s => {
      const x = xScale(s.serverEventPcMs);
      const isOdd = dateSec(s) % 2 === 1;
      const isHighRtt = s.rttMs > rttThreshold && rttThreshold > 0;
      const cls = isHighRtt ? 'sample-dot rtt-high' : (isOdd ? 'sample-dot odd' : 'sample-dot even');
      const r = Math.min(8, Math.max(3, 3 + Math.log10(Math.max(1, s.rttMs)) * 1.5));

      const circle = document.createElementNS(SVG_NS, 'circle');
      circle.setAttribute('class', cls);
      circle.setAttribute('cx', x.toFixed(1));
      circle.setAttribute('cy', yMid);
      circle.setAttribute('r', r.toFixed(1));
      circle.addEventListener('mouseenter', e => showTooltip(e, s, t0));
      circle.addEventListener('mouseleave', hideTooltip);
      circle.addEventListener('mousemove', e => moveTooltip(e));
      timelineEl.appendChild(circle);
    });

    // 요약
    const elapsedTotal = (totalMs / 1000).toFixed(2);
    let label = methodLabel(data.method, edges.length, data.acceptedCount);
    if (state && state.lastMeasureMode === 'fast') label = '⚡ 빠른 측정 · ' + label + ' (정확도 낮음)';
    const measurementNote = data.measurementNote === 'interpark-final-ticket-page'
      ? ' | 측정경로 nol.interpark.com/ticket'
      : '';
    const widthPart = (typeof data.intersectWidthMs === 'number' && data.intersectWidthMs > 0)
      ? ` | 교집합 폭 ${Math.round(data.intersectWidthMs)}ms`
      : '';
    detailsSummary.innerHTML =
      `방법: <strong>${label}</strong> | ` +
      `샘플 <strong>${samples.length}</strong>개 | ` +
      `edge <strong>${edges.length}</strong>개 | ` +
      `총 측정 ${elapsedTotal}초 | ` +
      `RTT median ${Math.round(rttMedian)}ms | ` +
      `±${Math.round(data.ci95Ms || 0)}ms${widthPart}${measurementNote}`;
  }

  function showTooltip(evt, s, t0) {
    const elapsed = ((s.serverEventPcMs - t0) / 1000).toFixed(3);
    const responseLag = (s.pcAtT2Ms - s.serverEventPcMs).toFixed(1);
    const dateStr = new Date(s.serverDateMs).toISOString().replace('T', ' ').replace(/\.\d+Z$/, '');
    tooltipEl.innerHTML =
      `idx ${s.idx} · 서버추정 t+${elapsed}s<br>` +
      `RTT ${s.rttMs.toFixed(1)}ms<br>` +
      `응답점은 +${responseLag}ms 뒤<br>` +
      `Date ${dateStr} UTC`;
    tooltipEl.hidden = false;
    moveTooltip(evt);
  }
  function moveTooltip(evt) {
    const rect = detailsEl.getBoundingClientRect();
    tooltipEl.style.left = (evt.clientX - rect.left + 12) + 'px';
    tooltipEl.style.top = (evt.clientY - rect.top + 12) + 'px';
  }
  function hideTooltip() { tooltipEl.hidden = true; }

  fetchState();
  setInterval(fetchState, 1000);
  setInterval(function() {
    // 측정 또는 재측정이 새로 끝났으면 details 자동 갱신.
    // 기존값 유지 재측정은 lastMeasureAt이 바뀌지 않으므로 finishedAt도 본다.
    if (!detailsOpen || !state) return;
    const measureChanged = state.lastMeasureAt && state.lastMeasureAt !== lastRenderedAt;
    const remeasureChanged = state.lastRemeasureFinishedAt && state.lastRemeasureFinishedAt !== lastRenderedRemeasureAt;
    if (measureChanged || remeasureChanged) {
      lastRenderedAt = state.lastMeasureAt;
      lastRenderedRemeasureAt = state.lastRemeasureFinishedAt;
      refreshDetails();
    }
  }, 1500);
  loop();
})();
