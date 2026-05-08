(function() {
  const KST_OFFSET_MS = 9 * 60 * 60 * 1000;
  // 수강신청 등 "절대 빠르면 안 되는" 용도용 안전 마진.
  // 표시 시각 = 추정 서버 시각 - SAFETY_BIAS_MS. 항상 실제보다 늦게 표시된다.
  const SAFETY_BIAS_MS = 30;
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
  let reloadNoticeUntilMs = 0;
  let activeTargetUrl = null;

  const targetForm = document.getElementById('target-form');
  const targetInput = document.getElementById('target-url');

  try {
    const nav = performance.getEntriesByType('navigation')[0];
    const legacyReload = performance.navigation && performance.navigation.type === 1;
    const pendingReload = sessionStorage.getItem('server-clock-refresh') === '1';
    sessionStorage.removeItem('server-clock-refresh');
    localReloadRemeasure = pendingReload || (!!nav && nav.type === 'reload') || legacyReload;
  } catch (e) {
    localReloadRemeasure = false;
  }

  window.addEventListener('beforeunload', function() {
    try {
      sessionStorage.setItem('server-clock-refresh', '1');
    } catch (e) {}
  });

  function setStatusText(text, warn, prominent) {
    const st = document.getElementById('status');
    st.classList.toggle('warn', !!warn);
    st.classList.toggle('prominent', !!prominent);
    st.textContent = text;
  }

  if (localReloadRemeasure) {
    reloadNoticeUntilMs = performance.now() + 4000;
    setStatusText('새로고침중... 재측정 요청됨', false, true);
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
  }

  async function submitTarget(url) {
    const button = targetForm.querySelector('button');
    button.disabled = true;
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
      const targetChanged = nextTargetUrl !== (activeTargetUrl || '');
      activeTargetUrl = nextTargetUrl;
      targetInput.value = activeTargetUrl;
      if (targetChanged) resetClockBase();
      localReloadRemeasure = true;
      setStatusText(targetChanged ? '초기 측정 중... (약 6초)' : '재측정 중... (약 6초)', false, true);
      await fetchState();
    } catch (e) {
      setStatusText(e.message || 'URL 설정 실패', true, true);
    } finally {
      button.disabled = false;
    }
  }

  targetForm.addEventListener('submit', function(e) {
    e.preventDefault();
    submitTarget(targetInput.value);
  });

  async function fetchState() {
    try {
      const t0 = performance.now();
      const res = await fetch('/api/state', { cache: 'no-store' });
      const data = await res.json();
      const t1 = performance.now();
      const lag = (t1 - t0) / 2;

      const nextTargetUrl = data.targetUrl || '';
      if (activeTargetUrl === null) {
        activeTargetUrl = nextTargetUrl;
        targetInput.value = activeTargetUrl;
      } else if (nextTargetUrl !== activeTargetUrl) {
        activeTargetUrl = nextTargetUrl;
        targetInput.value = activeTargetUrl;
        resetClockBase();
      }
      if (data.status !== 'idle' && data.status !== 'queued' && (data.status !== 'measuring' || data.lastMeasureAt)) {
        const serverAtSend = data.pcSendTimeAtMs + data.offsetMs;
        setClockBase(serverAtSend + lag, t1);
      }
      state = data;
      if (data.status === 'measuring' || data.status === 'queued') {
        localReloadRemeasure = true;
      } else if (data.lastMeasureRequestedAt && data.lastMeasureAt &&
          new Date(data.lastMeasureAt).getTime() >= new Date(data.lastMeasureRequestedAt).getTime()) {
        if (performance.now() >= reloadNoticeUntilMs) localReloadRemeasure = false;
      } else if (data.lastMeasureRequestedAt && data.lastRemeasureFinishedAt &&
          new Date(data.lastRemeasureFinishedAt).getTime() >= new Date(data.lastMeasureRequestedAt).getTime()) {
        if (performance.now() >= reloadNoticeUntilMs) localReloadRemeasure = false;
      }
    } catch (e) {
      console.warn('fetchState failed', e);
    }
  }

  function nowEstimateMs() {
    if (baseServerMs == null) return null;
    return baseServerMs + (performance.now() - basePerfMs);
  }

  function hasPendingRemeasure() {
    if (!state || !state.lastMeasureRequestedAt) return false;
    if (!state.lastMeasureAt) return true;
    return new Date(state.lastMeasureRequestedAt).getTime() > new Date(state.lastMeasureAt).getTime();
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
    const ms = estimateMs == null ? null : estimateMs - SAFETY_BIAS_MS;
    if (ms == null) {
      if (state) document.getElementById('host').textContent = state.host || 'URL을 입력하세요';
      document.getElementById('stats').textContent = '';
      document.getElementById('ntp').textContent = '';
      if (!state || state.status === 'idle') {
        setStatusText('측정할 URL을 입력하세요', false, true);
      } else if (state.status === 'queued') {
        setStatusText('측정 대기 중...', false, true);
      } else if (state.status === 'measuring') {
        setStatusText('초기 측정 중... (약 6초)', false, true);
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
    document.getElementById('stats').textContent =
      `측정: ${ago}초 전  RTT ${Math.round(state.rttMedianMs || 0)}ms  ±${Math.round(state.ci95Ms || 0)}ms  안전마진 -${SAFETY_BIAS_MS}ms`;

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
      setStatusText('측정 대기 중...', false, true);
    } else if (state.status === 'measuring') {
      setStatusText(hasPendingRemeasure() || localReloadRemeasure ? '재측정 중... (약 6초)' : '초기 측정 중...', false, hasPendingRemeasure() || localReloadRemeasure);
    } else if (state.lastRemeasureResult === 'rejected') {
      const delta = Math.round(state.lastRemeasureDeltaMs || 0);
      setStatusText(`재측정 편차 ${delta}ms 초과: 기존값 유지`, true, true);
    } else if (state.lastRemeasureResult === 'accepted' && state.lastRemeasureAttempts > 1) {
      setStatusText('재측정 완료 (2회차 반영)', false, true);
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

  fetchState();
  setInterval(fetchState, 1000);
  loop();
})();
