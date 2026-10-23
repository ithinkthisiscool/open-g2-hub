/* apply the saved colour theme before the body renders (no flash).
     none/unknown = "Even" following the system light/dark setting; else even-light | even-dark | green | amber. */
  try { var t = localStorage.getItem('g2hub.theme'); if (t === 'amber' || t === 'green' || t === 'even-light' || t === 'even-dark') document.documentElement.dataset.theme = t; } catch (e) {}
