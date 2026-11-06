// Prepared muted clips over the existing camera hole. Decode failure reveals live gameplay.
(() => {
  const el = (tag, cls, text) => {
    const node = document.createElement(tag); node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  };
  let panel, key, video, label, last, watchdog, picture, context, mediaFailure;
  let fit = () => {};
  const failures = [];
  const params = new URLSearchParams(location.search);
  const cinema = params.get('recap_layout') === 'cinema';
  function release() {
    clearTimeout(watchdog);
    picture=null; context=null;
    if (video) {
      const old = video; video = null;
      old.pause(); old.removeAttribute('src'); old.load();
    }
  }
  function liveLabel() {
    const live = last && last.live;
    return `${mediaFailure || last?.fallback ? (mediaFailure || last.fallback) + ' · ' : ''}LIVE GAMEPLAY${live && live.subject ? ' · ' + live.subject : ''} · earlier shift narrated · Graphics copyright Wube Software`;
  }
  function cameraRect() {
    const cam = document.getElementById('cam-main');
    // The normal renderer lays out the actual program's hole (including a trio).
    if (cam && cam.offsetWidth && cam.offsetHeight) {
      for (const [k,v] of Object.entries({x:cam.offsetLeft,y:cam.offsetTop,w:cam.offsetWidth,h:cam.offsetHeight}))
        panel.style.setProperty('--sr-'+k,v+'px');
    }
    fit();
  }
  function render(s) {
    const recap = s && s.shift_recap;
    const active = !!(recap && recap.active && !recap.holding);
    document.body.classList.toggle('recap-active', active);
    if (!panel) {
      const stage = document.getElementById('stage'); if (!stage) return;
      panel = el('section','shift-recap'); panel.id='shift-recap';
      panel.setAttribute('aria-label','Recorded shift recap'); panel.hidden=true; stage.appendChild(panel);
    }
    panel.hidden = !active;
    if (!active) { release(); panel.replaceChildren(); key=null; last=null; fit=()=>{}; return; }
    last = recap;
    requestAnimationFrame(cameraRect);
    const media = recap.media && (recap.media.kind === 'video' || recap.media.detail || recap.media.fallback) ? recap.media : null;
    if (context && Number(recap.elapsed || 0) >= Number(media?.detail?.context_seconds || 2)) context.hidden=true;
    const next = JSON.stringify([recap.run,recap.phase,recap.id,recap.title,recap.text,
      recap.speaker,recap.time_label,recap.fallback,media]);
    if (next === key) {
      if (!panel.classList.contains('sr-playing')) label.textContent=liveLabel();
      return;
    }
    key=next; release(); mediaFailure=null; panel.replaceChildren();
    panel.classList.toggle('sr-playing',false);
    panel.classList.toggle('sr-cinema',cinema);
    panel.classList.toggle('sr-anchored',!!media && media.kind === 'image');
    const header=el('header','sr-head');
    header.append(el('div','sr-kicker',`${recap.run || ''} · ${recap.phase === 'transition' ? 'SHIFT CHANGE' : 'SHIFT RECAP'}`),
      el('h2','sr-title',recap.title || 'Shift recap'));
    const figure=el('figure','sr-media');
    const caption=el('footer','sr-caption'), meta=el('div','sr-meta');
    meta.append(el('b','sr-speaker',recap.speaker || 'Rook & Vale'),el('span','sr-time',recap.time_label || 'Recorded shift'));
    const spoken=el('p','sr-text',recap.text || '');
    label=el('div','sr-recorded',liveLabel());
    caption.append(meta,spoken,label); panel.append(figure,header,caption);
    if (media && media.kind === 'image') {
      const node=el('img','sr-source'); picture=node;
      const failed=()=>{
        if(picture!==node)return;
        release(); figure.replaceChildren(); panel.classList.toggle('sr-playing',false);
        mediaFailure='OVERVIEW FALLBACK · recorded detail unavailable'; label.textContent=liveLabel();
        failures.push({id:recap.id,asset:media.asset,error:'detail image unavailable'});
      };
      const svg=(box,cls)=>{
        const ns='http://www.w3.org/2000/svg', root=document.createElementNS(ns,'svg');
        root.setAttribute('class',cls); root.setAttribute('viewBox',box.join(' '));
        root.setAttribute('preserveAspectRatio','xMidYMid meet');
        const image=document.createElementNS(ns,'image');
        image.setAttribute('href',media.url); image.setAttribute('width',node.naturalWidth); image.setAttribute('height',node.naturalHeight);
        root.append(image);
        if(media.detail){
          const a=media.detail, mark=document.createElementNS(ns,'ellipse');
          for(const [k,v] of Object.entries({cx:a.point[0],cy:a.point[1],rx:a.radius[0],ry:a.radius[1],
            fill:'none',stroke:'#ffdf55','stroke-width':3,'vector-effect':'non-scaling-stroke'})) mark.setAttribute(k,v);
          root.append(mark);
        }
        return root;
      };
      node.addEventListener('error',failed,{once:true});
      node.addEventListener('load',()=>{
        if(picture!==node)return;
        clearTimeout(watchdog);
        if(media.detail && (node.naturalWidth!==media.detail.px[0] || node.naturalHeight!==media.detail.px[1])) {failed();return;}
        figure.append(svg(media.detail?.crop || [0,0,node.naturalWidth,node.naturalHeight],media.detail ? 'sr-detail sr-target' : 'sr-detail'));
        if(media.detail){
          context=el('div','sr-context');
          context.append(svg([0,0,node.naturalWidth,node.naturalHeight],'sr-wide'),el('span','','Wider recorded view'));
          context.hidden=Number(last?.elapsed || 0)>=media.detail.context_seconds;
          figure.append(context);
        }
        panel.classList.toggle('sr-playing',true);
        label.textContent=`${media.fallback || 'RECORDED DETAIL · '+media.detail.name} · ${media.recorded_time || ''}${media.detail ? ' · '+media.detail.timing+' ('+media.detail.delta_seconds+'s)' : ''} · Graphics copyright Wube Software`;
        fit();
      },{once:true});
      node.src=media.url; watchdog=setTimeout(failed,2500);
    } else if (media) {
      const node=el('video','sr-picture'); video=node;
      node.muted=true; node.defaultMuted=true; node.autoplay=true; node.playsInline=true; node.loop=true;
      node.setAttribute('muted',''); node.setAttribute('playsinline','');
      const failed=() => {
        if (video !== node) return;
        release(); figure.replaceChildren(); panel.classList.toggle('sr-playing',false);
        label.textContent=liveLabel();
        failures.push({id:recap.id,asset:media.asset,error:'clip unavailable; live gameplay exposed'});
      };
      const stalled=() => { clearTimeout(watchdog); watchdog=setTimeout(failed,2500); };
      node.addEventListener('error',failed,{once:true});
      node.addEventListener('waiting',stalled);
      node.addEventListener('stalled',stalled);
      node.addEventListener('playing',() => {
        if (video !== node) return;
        clearTimeout(watchdog); panel.classList.toggle('sr-playing',true);
        label.textContent=`RECORDED CLIP · ${media.subject || 'shift'} · ${media.recorded_time || ''} · Graphics copyright Wube Software`;
      });
      node.addEventListener('loadedmetadata',() => {
        if (video !== node) return;
        const offset=Math.max(0,Number(recap.elapsed || 0)+Number(media.offset || 0));
        if (Number.isFinite(node.duration) && node.duration > 0) node.currentTime=offset % node.duration;
        const playing=node.play(); if(playing && playing.catch) playing.catch(failed);
      },{once:true});
      figure.append(node); node.src=media.url; stalled();
    }
    fit=() => {
      if (!caption.isConnected || !caption.clientHeight) return;
      if(panel.classList.contains('sr-anchored')) {
        figure.style.top=(header.offsetHeight+8)+'px';
        figure.style.bottom=(panel.clientHeight-caption.offsetTop+12)+'px';
      }
      let size=parseFloat(getComputedStyle(spoken).fontSize);
      while(caption.scrollHeight > caption.clientHeight+1 && size > 18) spoken.style.fontSize=--size+'px';
    };
    requestAnimationFrame(fit);
    if(document.fonts && document.fonts.ready) document.fonts.ready.then(fit);
  }
  window.PogShiftRecap={render,failures};
})();
