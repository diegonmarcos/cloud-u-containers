(function(){
  /* ═══ Stars ═══ */
  var s=document.getElementById('stars'),w=window.innerWidth,h=window.innerHeight;
  for(var i=0;i<80;i++){
    var d=document.createElement('div');d.className='star';
    var sz=Math.random()*2+1;
    d.style.cssText='width:'+sz+'px;height:'+sz+'px;top:'+Math.random()*h+'px;left:'+Math.random()*w+'px;--d:'+(Math.random()*4+2)+'s';
    s.appendChild(d);
  }

  /* ═══ API Base ═══ */
  var API_BASE=window.location.pathname.replace(/\/dash\/?$/,'');

  /* ═══ Fetch helper ═══ */
  function apiFetch(path,opts){
    opts=opts||{};
    opts.credentials='include'; // Send cookies (Authelia session)
    if(!opts.signal)opts.signal=AbortSignal.timeout(opts.timeout||30000);
    delete opts.timeout;
    return fetch(API_BASE+path,opts).then(function(r){
      if(!r.ok)throw new Error('HTTP '+r.status);
      var ct=r.headers.get('content-type')||'';
      if(ct.indexOf('application/json')>=0)return r.json();
      return r.text();
    });
  }

  /* ═══ Tab switching ═══ */
  document.querySelectorAll('.tab-btn').forEach(function(btn){
    btn.addEventListener('click',function(){
      document.querySelectorAll('.tab-btn').forEach(function(b){b.classList.remove('active')});
      document.querySelectorAll('.tab-content').forEach(function(c){c.classList.remove('active')});
      btn.classList.add('active');
      document.getElementById('tab-'+btn.dataset.tab).classList.add('active');
    });
  });

  /* ═══ Confirmation modal ═══ */
  var confirmCb=null;
  function showConfirm(title,msg,cb){
    document.getElementById('confirm-title').textContent=title;
    document.getElementById('confirm-msg').textContent=msg;
    document.getElementById('confirm-modal').classList.remove('hidden');
    confirmCb=cb;
  }
  document.getElementById('confirm-cancel').addEventListener('click',function(){
    document.getElementById('confirm-modal').classList.add('hidden');confirmCb=null;
  });
  document.getElementById('confirm-ok').addEventListener('click',function(){
    document.getElementById('confirm-modal').classList.add('hidden');
    if(confirmCb)confirmCb();confirmCb=null;
  });

  /* ═══ Utility ═══ */
  function esc(s){if(s==null)return'';return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
  function stClass(v){
    if(!v)return'st-off';
    var l=String(v).toLowerCase();
    if(l==='running'||l==='up'||l==='healthy'||l==='online'||l==='ok'||l==='true'||l==='reachable')return'st-ok';
    if(l==='degraded'||l==='warning'||l==='warn'||l==='partial')return'st-warn';
    if(l==='down'||l==='error'||l==='exited'||l==='stopped'||l==='false'||l==='unreachable'||l==='fail')return'st-err';
    return'st-off';
  }

  /* ═══════════════════════════════════════════
     HEALTH TAB
     ═══════════════════════════════════════════ */
  document.getElementById('btn-health-refresh-all').addEventListener('click',function(){
    loadHealthStatus();
    document.getElementById('btn-tier1').click();
    document.getElementById('btn-tier2').click();
    document.getElementById('btn-tier3').click();
  });

  var arTimer=null;
  document.getElementById('btn-ar-toggle').addEventListener('click',function(){
    if(arTimer){
      clearInterval(arTimer);arTimer=null;
      this.textContent='Enable 30s';
      document.getElementById('ar-label').textContent='Auto-refresh: OFF';
      document.getElementById('ar-label').classList.remove('active');
    }else{
      loadHealthStatus();
      arTimer=setInterval(loadHealthStatus,30000);
      this.textContent='Disable';
      document.getElementById('ar-label').textContent='Auto-refresh: ON (30s)';
      document.getElementById('ar-label').classList.add('active');
    }
  });

  document.getElementById('btn-health-status').addEventListener('click',loadHealthStatus);
  function loadHealthStatus(){
    var el=document.getElementById('out-health-status');
    el.innerHTML='<span class="loading">loading status...</span>';
    apiFetch('/health/status',{timeout:30000}).then(function(d){
      renderHealthStatus(el,d);
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  }

  function renderHealthStatus(el,d){
    var h='';
    var declared=d.declared||{};
    var deployed=d.deployed||{};
    var drift=d.drift||[];

    var dvms=declared.vms||{};
    var totals=declared.totals||declared.counts||{};
    h+='<h3>Declared</h3>';
    h+='<table><tr><th>VM</th><th>Services</th><th>Containers</th></tr>';
    for(var id in dvms){
      var v=dvms[id],svcs=v.services||{},sc=Object.keys(svcs).length,cc=0;
      for(var sn in svcs)cc+=(Array.isArray(svcs[sn])?svcs[sn].length:1);
      h+='<tr><td><code>'+esc(id)+'</code></td><td>'+sc+'</td><td>'+cc+'</td></tr>';
    }
    h+='</table>';
    if(totals.vms!=null)h+='<p style="font-size:.7rem">'+totals.vms+' VMs, '+totals.services+' services, '+totals.containers+' containers</p>';

    var depVms=deployed.vms||deployed;
    if(typeof depVms==='object'&&!Array.isArray(depVms)){
      h+='<h3>Deployed</h3>';
      for(var did in depVms){
        var dv=depVms[did],dcs=dv.containers||[];
        h+='<div style="margin:.3rem 0"><code>'+esc(did)+'</code> — ';
        h+='<span class="st-ok">'+(dv.running||0)+' running</span>, ';
        h+='<span class="'+(dv.stopped>0?'st-warn':'st-off')+'">'+(dv.stopped||0)+' stopped</span>';
        h+='</div>';
      }
    }

    if(drift.length>0||Array.isArray(drift)){
      h+='<h3>Drift</h3>';
      var hasDrift=false;
      if(Array.isArray(drift)){
        h+='<table><tr><th>Container</th><th>VM</th><th>Status</th></tr>';
        for(var i=0;i<drift.length;i++){
          var dr=drift[i];
          var cls=stClass(dr.status);
          if(dr.status!=='ok')hasDrift=true;
          h+='<tr><td><code>'+esc(dr.container||dr.name)+'</code></td><td>'+esc(dr.vm||dr.vmId||'')+'</td>';
          h+='<td class="'+cls+'">'+esc(dr.status)+'</td></tr>';
        }
        h+='</table>';
      }
      h+='<p>'+(hasDrift?'<span class="st-err">Drift detected</span>':'<span class="st-ok">No drift</span>')+'</p>';
    }

    el.innerHTML=h;
  }

  /* Tier 1 */
  document.getElementById('btn-tier1').addEventListener('click',function(){
    var el=document.getElementById('out-tier1');
    el.innerHTML='<span class="loading">probing reachability...</span>';
    apiFetch('/health/tier1',{timeout:15000}).then(function(d){
      var rows=Array.isArray(d)?d:(d.results||[d]);
      var h='<table><tr><th>VM</th><th>Alias</th><th>IP</th><th>Reachable</th><th>Latency</th></tr>';
      for(var i=0;i<rows.length;i++){
        var r=rows[i];
        h+='<tr><td><code>'+esc(r.vm||r.vmId)+'</code></td><td>'+esc(r.alias||'')+'</td><td><code>'+esc(r.ip||'')+'</code></td>';
        h+='<td class="'+stClass(r.reachable?'ok':'fail')+'">'+(r.reachable?'YES':'NO')+'</td>';
        h+='<td>'+(r.latencyMs!=null?r.latencyMs+'ms':'—')+'</td></tr>';
      }
      h+='</table>';
      el.innerHTML=h;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  });

  /* Tier 2 */
  document.getElementById('btn-tier2').addEventListener('click',function(){
    var el=document.getElementById('out-tier2');
    el.innerHTML='<span class="loading">testing SSH auth...</span>';
    apiFetch('/health/tier2',{timeout:20000}).then(function(d){
      var rows=Array.isArray(d)?d:(d.results||[d]);
      var h='<table><tr><th>VM</th><th>Alias</th><th>Reachable</th><th>SSH</th><th>Error</th></tr>';
      for(var i=0;i<rows.length;i++){
        var r=rows[i];
        h+='<tr><td><code>'+esc(r.vm||r.vmId)+'</code></td><td>'+esc(r.alias||'')+'</td>';
        h+='<td class="'+stClass(r.reachable?'ok':'fail')+'">'+(r.reachable?'YES':'NO')+'</td>';
        h+='<td class="'+stClass(r.sshOk?'ok':'fail')+'">'+(r.sshOk?'OK':'FAIL')+'</td>';
        h+='<td>'+esc(r.sshError||'—')+'</td></tr>';
      }
      h+='</table>';
      el.innerHTML=h;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  });

  /* Tier 3 */
  document.getElementById('btn-tier3').addEventListener('click',function(){
    var el=document.getElementById('out-tier3');
    el.innerHTML='<span class="loading">gathering resources (may take ~8s)...</span>';
    apiFetch('/health/tier3',{timeout:30000}).then(function(d){
      var rows=Array.isArray(d)?d:(d.results||[d]);
      var h='';
      for(var i=0;i<rows.length;i++){
        var r=rows[i],res=r.resources||{};
        h+='<div class="card" style="margin:.3rem 0;padding:.5rem .75rem">';
        h+='<strong>'+esc(r.vm||r.vmId||r.alias)+'</strong>';
        h+=' <span class="badge '+(r.reachable?'badge-ok':'badge-err')+'">'+(r.reachable?'UP':'DOWN')+'</span>';
        if(r.sshOk!=null)h+=' <span class="badge '+(r.sshOk?'badge-ok':'badge-err')+'">SSH '+(r.sshOk?'OK':'FAIL')+'</span>';
        if(res.uptime)h+='<br><span style="font-size:.7rem;color:#495057">Uptime: '+esc(res.uptime)+'</span>';
        if(res.memoryUsed!=null&&res.memoryTotal!=null){
          h+='<br><span style="font-size:.7rem">Memory: '+esc(res.memoryUsed)+' / '+esc(res.memoryTotal)+' (free: '+esc(res.memoryFree)+')</span>';
        }
        if(res.diskPercent!=null){
          var dc=parseInt(res.diskPercent)>85?'st-err':(parseInt(res.diskPercent)>70?'st-warn':'st-ok');
          h+='<br><span style="font-size:.7rem">Disk: <span class="'+dc+'">'+esc(res.diskPercent)+'</span> ('+esc(res.diskUsed)+' / '+esc(res.diskTotal)+')</span>';
        }
        var cts=r.containers||[];
        if(cts.length>0){
          h+='<table style="margin:.3rem 0"><tr><th>Container</th><th>Status</th></tr>';
          for(var j=0;j<cts.length;j++){
            var c=cts[j];
            h+='<tr><td>'+esc(c.name)+'</td><td class="'+stClass(c.status||c.state)+'">'+esc(c.status||c.state)+'</td></tr>';
          }
          h+='</table>';
        }
        h+='</div>';
      }
      el.innerHTML=h;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  });

  /* ═══════════════════════════════════════════
     TOPOLOGY TAB
     ═══════════════════════════════════════════ */
  document.getElementById('btn-topo-refresh-all').addEventListener('click',function(){
    document.getElementById('btn-topo').click();
    document.getElementById('btn-topo-sec').click();
    document.getElementById('btn-topo-drift').click();
  });

  document.getElementById('btn-topo').addEventListener('click',function(){
    var el=document.getElementById('out-topo');
    el.innerHTML='<span class="loading">loading topology...</span>';
    apiFetch('/topology',{timeout:15000}).then(function(d){
      var h='';
      var vms=d.vms||[];
      if(vms.length>0){
        h+='<h3>VMs ('+vms.length+')</h3>';
        for(var i=0;i<vms.length;i++){
          var vm=vms[i];
          h+='<div class="card" style="margin:.3rem 0;padding:.5rem .75rem">';
          h+='<strong>'+esc(vm.alias||vm.id)+'</strong>';
          if(vm.ip)h+=' <code>'+esc(vm.ip)+'</code>';
          if(vm.method)h+=' <span class="badge badge-purple">'+esc(vm.method)+'</span>';
          var svcs=vm.services||[];
          if(svcs.length>0){
            h+='<div style="margin-top:.3rem;font-size:.7rem">';
            for(var j=0;j<svcs.length;j++){
              h+='<code style="margin-right:.3rem">'+esc(svcs[j])+'</code>';
            }
            h+='</div>';
          }
          h+='</div>';
        }
      }

      var services=d.services||[];
      if(services.length>0){
        h+='<h3>Services ('+services.length+')</h3>';
        h+='<table><tr><th>Name</th><th>Category</th><th>VM</th><th>Domain</th><th>On-Disk</th></tr>';
        for(var i=0;i<services.length;i++){
          var svc=services[i];
          h+='<tr><td><code>'+esc(svc.name)+'</code></td><td>'+esc(svc.category||'')+'</td>';
          h+='<td>'+esc(svc.vmAlias||svc.vm||'')+'</td>';
          h+='<td>'+(svc.domain?'<a href="https://'+esc(svc.domain)+'" target="_blank">'+esc(svc.domain)+'</a>':'—')+'</td>';
          h+='<td class="'+stClass(svc.discovered?'ok':'fail')+'">'+(svc.discovered?'YES':'NO')+'</td></tr>';
        }
        h+='</table>';
      }

      if(d.summary)h+='<pre>'+esc(typeof d.summary==='string'?d.summary:JSON.stringify(d.summary,null,2))+'</pre>';
      el.innerHTML=h;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  });

  document.getElementById('btn-topo-sec').addEventListener('click',function(){
    var el=document.getElementById('out-topo-sec');
    el.innerHTML='<span class="loading">loading security topology...</span>';
    apiFetch('/topology/security',{timeout:15000}).then(function(d){
      var h='';
      var exposed=d.exposedServices||[];
      if(exposed.length>0){
        h+='<h3>Exposed Services ('+exposed.length+')</h3>';
        h+='<table><tr><th>Name</th><th>Domain</th><th>Auth</th><th>VM</th></tr>';
        for(var i=0;i<exposed.length;i++){
          var s=exposed[i];
          h+='<tr><td><code>'+esc(s.name)+'</code></td><td>'+esc(s.domain||'')+'</td>';
          h+='<td>'+esc(s.auth||'')+'</td><td>'+esc(s.vm||'')+'</td></tr>';
        }
        h+='</table>';
      }
      var secrets=d.secretsStatus||[];
      if(secrets.length>0){
        h+='<h3>Secrets Status</h3>';
        h+='<table><tr><th>Service</th><th>Has Secrets</th><th>Encrypted</th></tr>';
        for(var i=0;i<secrets.length;i++){
          var s=secrets[i];
          h+='<tr><td><code>'+esc(s.name||s.service)+'</code></td>';
          h+='<td class="'+stClass(s.hasSecrets?'ok':'off')+'">'+(s.hasSecrets?'YES':'NO')+'</td>';
          h+='<td class="'+stClass(s.encrypted?'ok':(s.hasSecrets?'fail':'off'))+'">'+(s.encrypted?'YES':(s.hasSecrets?'NO':'N/A'))+'</td></tr>';
        }
        h+='</table>';
      }
      if(d.summary)h+='<pre>'+esc(typeof d.summary==='string'?d.summary:JSON.stringify(d.summary,null,2))+'</pre>';
      el.innerHTML=h;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  });

  document.getElementById('btn-topo-drift').addEventListener('click',function(){
    var el=document.getElementById('out-topo-drift');
    el.innerHTML='<span class="loading">checking drift...</span>';
    apiFetch('/topology/drift',{timeout:15000}).then(function(d){
      var h='';
      var onDisk=d.onDiskOnly||[];
      var config=d.configOnly||[];
      if(onDisk.length>0){
        h+='<h3>On Disk Only <span class="badge badge-warn">'+onDisk.length+'</span></h3>';
        h+='<p style="font-size:.7rem">Directories found on disk but not in config.json:</p><ul>';
        for(var i=0;i<onDisk.length;i++)h+='<li><code>'+esc(onDisk[i])+'</code></li>';
        h+='</ul>';
      }
      if(config.length>0){
        h+='<h3>Config Only <span class="badge badge-err">'+config.length+'</span></h3>';
        h+='<p style="font-size:.7rem">In config.json but no directory on disk:</p><ul>';
        for(var i=0;i<config.length;i++)h+='<li><code>'+esc(config[i])+'</code></li>';
        h+='</ul>';
      }
      if(onDisk.length===0&&config.length===0){
        h+='<p class="st-ok">No drift detected — config matches disk.</p>';
      }
      if(d.summary)h+='<pre>'+esc(d.summary)+'</pre>';
      el.innerHTML=h;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  });

  /* ═══════════════════════════════════════════
     TESTS TAB
     ═══════════════════════════════════════════ */
  document.getElementById('btn-test-run').addEventListener('click',function(){
    var suite=document.getElementById('test-suite').value;
    var el=document.getElementById('out-tests');
    var btn=this;
    btn.disabled=true;
    el.innerHTML='<span class="loading">running '+esc(suite)+' tests...</span>';
    apiFetch('/tests/'+suite,{timeout:120000}).then(function(d){
      var tests=d.tests||d.results||[];
      var h='<div class="flex-row" style="margin-bottom:.5rem">';
      h+='<span class="badge badge-ok">'+esc(d.passed||0)+' passed</span>';
      h+='<span class="badge badge-err">'+esc(d.failed||0)+' failed</span>';
      h+='<span class="badge badge-off">'+esc(d.total||tests.length)+' total</span>';
      if(d.timeMs!=null)h+='<span style="font-size:.65rem;color:#495057">'+d.timeMs+'ms</span>';
      h+='</div>';
      h+='<table><tr><th>Test</th><th>Target</th><th>Result</th><th>Time</th><th>Details</th></tr>';
      for(var i=0;i<tests.length;i++){
        var t=tests[i];
        h+='<tr><td>'+esc(t.name)+'</td><td>'+esc(t.target||'')+'</td>';
        h+='<td class="'+stClass(t.passed?'ok':'fail')+'">'+(t.passed?'PASS':'FAIL')+'</td>';
        h+='<td>'+(t.timeMs!=null?t.timeMs+'ms':'—')+'</td>';
        h+='<td style="white-space:normal;max-width:300px;font-size:.65rem">'+esc(t.details||t.error||'')+'</td></tr>';
      }
      h+='</table>';
      el.innerHTML=h;
      btn.disabled=false;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>';btn.disabled=false});
  });

  /* ═══════════════════════════════════════════
     SERVICES TAB
     ═══════════════════════════════════════════ */
  document.getElementById('btn-services').addEventListener('click',loadServices);
  function loadServices(){
    var el=document.getElementById('out-services');
    el.innerHTML='<span class="loading">loading services...</span>';
    apiFetch('/services',{timeout:15000}).then(function(d){
      var svcs=Array.isArray(d)?d:(d.services||[]);
      svcs.sort(function(a,b){return(a.name||'').localeCompare(b.name||'')});
      var h='<table><tr><th>Name</th><th>Domain</th><th>VM</th><th>Category</th><th>API Spec</th><th></th></tr>';
      for(var i=0;i<svcs.length;i++){
        var s=svcs[i];
        h+='<tr><td><code>'+esc(s.name)+'</code></td>';
        h+='<td>'+(s.domain?'<a href="https://'+esc(s.domain)+'" target="_blank">'+esc(s.domain)+'</a>':'—')+'</td>';
        h+='<td>'+esc(s.alias||s.vm||'')+'</td>';
        h+='<td>'+esc(s.category||'')+'</td>';
        h+='<td class="'+stClass(s.hasSpec?'ok':'off')+'">'+(s.hasSpec?'YES':'—')+'</td>';
        h+='<td><button class="rbtn blue" style="padding:.15rem .4rem;font-size:.6rem" data-svc-detail="'+esc(s.name)+'">Details</button></td></tr>';
      }
      h+='</table>';
      h+='<p style="font-size:.7rem;color:#495057">'+svcs.length+' services</p>';
      el.innerHTML=h;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  }

  document.getElementById('out-services').addEventListener('click',function(e){
    var btn=e.target.closest('[data-svc-detail]');
    if(!btn)return;
    var name=btn.dataset.svcDetail;
    var card=document.getElementById('svc-detail-card');
    var el=document.getElementById('out-svc-detail');
    document.getElementById('svc-detail-title').textContent=name;
    card.classList.remove('hidden');
    el.innerHTML='<span class="loading">loading...</span>';
    apiFetch('/services/'+encodeURIComponent(name),{timeout:15000}).then(function(d){
      var h='<pre>'+esc(JSON.stringify(d,null,2))+'</pre>';
      if(d.hasSpec||d.specUrl){
        h+='<button class="rbtn blue" id="btn-load-spec" data-spec-svc="'+esc(name)+'" style="margin-top:.5rem">Load API Spec</button>';
        h+='<div id="out-spec"></div>';
      }
      el.innerHTML=h;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  });

  document.getElementById('out-svc-detail').addEventListener('click',function(e){
    var btn=e.target.closest('[data-spec-svc]');
    if(!btn)return;
    var name=btn.dataset.specSvc;
    var el=document.getElementById('out-spec');
    if(!el)return;
    el.innerHTML='<span class="loading">fetching spec...</span>';
    apiFetch('/services/'+encodeURIComponent(name)+'/spec',{timeout:15000}).then(function(d){
      el.innerHTML='<pre>'+esc(JSON.stringify(d,null,2))+'</pre>';
    }).catch(function(e2){el.innerHTML='<span class="st-err">'+esc(e2.message)+'</span>'});
  });

  document.getElementById('btn-svc-close').addEventListener('click',function(){
    document.getElementById('svc-detail-card').classList.add('hidden');
  });

  /* ═══════════════════════════════════════════
     CLOUD TAB
     ═══════════════════════════════════════════ */
  document.getElementById('btn-cloud').addEventListener('click',function(){
    var el=document.getElementById('out-cloud');
    el.innerHTML='<span class="loading">loading cloud summary...</span>';
    apiFetch('/cloud/summary',{timeout:30000}).then(function(d){
      var h='';
      h+='<h3>OCI (Oracle Cloud)</h3>';
      var oci=d.oci||{};
      var ociI=oci.instances;
      if(ociI){
        if(ociI.error){
          h+='<p class="st-warn">Instances: '+esc(ociI.error)+'</p>';
        }else{
          var instances=Array.isArray(ociI)?ociI:(ociI.instances||[]);
          if(instances.length>0){
            h+='<table><tr><th>Name</th><th>Shape</th><th>State</th><th>Public IP</th></tr>';
            for(var i=0;i<instances.length;i++){
              var inst=instances[i];
              h+='<tr><td>'+esc(inst.displayName||inst.name)+'</td><td>'+esc(inst.shape||'')+'</td>';
              h+='<td class="'+stClass(inst.lifecycleState||inst.state)+'">'+esc(inst.lifecycleState||inst.state)+'</td>';
              h+='<td><code>'+esc(inst.publicIp||inst.ip||'—')+'</code></td></tr>';
            }
            h+='</table>';
          }else{h+='<p style="font-size:.7rem">No instances data</p>'}
        }
      }
      if(oci.costs){
        if(oci.costs.error)h+='<p class="st-warn" style="font-size:.7rem">Costs: '+esc(oci.costs.error)+'</p>';
        else h+='<pre style="font-size:.65rem">'+esc(JSON.stringify(oci.costs,null,2))+'</pre>';
      }

      h+='<h3>GCP (Google Cloud)</h3>';
      var gcp=d.gcp||{};
      var gcpI=gcp.instances;
      if(gcpI){
        if(gcpI.error){
          h+='<p class="st-warn">Instances: '+esc(gcpI.error)+'</p>';
        }else{
          var gInstances=Array.isArray(gcpI)?gcpI:(gcpI.instances||[]);
          if(gInstances.length>0){
            h+='<table><tr><th>Name</th><th>Zone</th><th>Status</th><th>IP</th></tr>';
            for(var i=0;i<gInstances.length;i++){
              var gi=gInstances[i];
              h+='<tr><td>'+esc(gi.name)+'</td><td>'+esc(gi.zone||'')+'</td>';
              h+='<td class="'+stClass(gi.status)+'">'+esc(gi.status)+'</td>';
              h+='<td><code>'+esc(gi.natIP||gi.ip||'—')+'</code></td></tr>';
            }
            h+='</table>';
          }else{h+='<p style="font-size:.7rem">No instances data</p>'}
        }
      }
      if(gcp.costs){
        if(gcp.costs.error)h+='<p class="st-warn" style="font-size:.7rem">Costs: '+esc(gcp.costs.error)+'</p>';
        else h+='<pre style="font-size:.65rem">'+esc(JSON.stringify(gcp.costs,null,2))+'</pre>';
      }

      el.innerHTML=h;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  });

  /* ═══════════════════════════════════════════
     FILES TAB
     ═══════════════════════════════════════════ */
  var fileCat=document.getElementById('file-category');
  var fileTgt=document.getElementById('file-target');
  var fileSub=document.getElementById('file-sub');
  var fileBtn=document.getElementById('btn-file-load');
  var cachedVMs=null;
  var cachedServices=null;

  function ensureVMList(cb){
    if(cachedVMs)return cb(cachedVMs);
    apiFetch('/health/declared',{timeout:10000}).then(function(d){
      var vms=d.vms||{};cachedVMs=Object.keys(vms);cb(cachedVMs);
    }).catch(function(){cachedVMs=['gcp-proxy','oci-apps','oci-apps-1','oci-mail','oci-analytics'];cb(cachedVMs)});
  }

  function ensureServiceList(cb){
    if(cachedServices)return cb(cachedServices);
    apiFetch('/services',{timeout:10000}).then(function(d){
      var svcs=Array.isArray(d)?d:(d.services||[]);
      cachedServices=svcs.map(function(s){return s.name}).sort();
      cb(cachedServices);
    }).catch(function(){cachedServices=[];cb(cachedServices)});
  }

  fileCat.addEventListener('change',function(){
    var cat=this.value;
    fileTgt.innerHTML='<option value="">-- target --</option>';
    fileSub.classList.add('hidden');
    fileTgt.disabled=true;fileBtn.disabled=true;
    if(!cat)return;

    if(cat==='config'||cat==='secrets'){
      ensureServiceList(function(list){
        for(var i=0;i<list.length;i++)fileTgt.innerHTML+='<option value="'+esc(list[i])+'">'+esc(list[i])+'</option>';
        fileTgt.disabled=false;
      });
    }else if(cat==='logs'){
      ensureVMList(function(list){
        for(var i=0;i<list.length;i++)fileTgt.innerHTML+='<option value="'+esc(list[i])+'">'+esc(list[i])+'</option>';
        fileTgt.disabled=false;
      });
    }else if(cat==='status'){
      ensureVMList(function(list){
        for(var i=0;i<list.length;i++)fileTgt.innerHTML+='<option value="'+esc(list[i])+'">'+esc(list[i])+'</option>';
        fileTgt.disabled=false;
      });
    }else if(cat==='report'){
      fileTgt.innerHTML='<option value="">-- type --</option>';
      fileTgt.innerHTML+='<option value="health">health</option>';
      fileTgt.innerHTML+='<option value="services">services</option>';
      fileTgt.innerHTML+='<option value="drift">drift</option>';
      fileTgt.disabled=false;
    }
  });

  fileTgt.addEventListener('change',function(){
    var cat=fileCat.value,tgt=this.value;
    fileSub.classList.add('hidden');
    fileBtn.disabled=!tgt;

    if(cat==='logs'&&tgt){
      fileSub.classList.remove('hidden');
      fileSub.innerHTML='<option value="">-- container (leave empty for all) --</option>';
      apiFetch('/health/deployed/'+encodeURIComponent(tgt),{timeout:10000}).then(function(d){
        var containers=(d.containers||[]);
        for(var i=0;i<containers.length;i++){
          var cn=containers[i].name||containers[i];
          fileSub.innerHTML+='<option value="'+esc(cn)+'">'+esc(cn)+'</option>';
        }
      }).catch(function(){});
    }

    if(cat==='config'&&tgt){
      fileSub.classList.remove('hidden');
      fileSub.innerHTML='<option value="">all (default)</option>';
      fileSub.innerHTML+='<option value="build.json">build.json</option>';
      fileSub.innerHTML+='<option value="docker-compose.yml">docker-compose.yml</option>';
      fileSub.innerHTML+='<option value="flake.nix">flake.nix</option>';
    }
  });

  fileBtn.addEventListener('click',function(){
    var cat=fileCat.value,tgt=fileTgt.value;
    var sub=fileSub.classList.contains('hidden')?'':fileSub.value;
    var el=document.getElementById('out-files');
    el.innerHTML='<span class="loading">loading...</span>';

    var path='';
    if(cat==='config'){
      path='/files/config/'+encodeURIComponent(tgt);
      if(sub)path+='/'+encodeURIComponent(sub);
    }else if(cat==='logs'){
      if(!sub){el.innerHTML='<span class="st-warn">Select a container for logs</span>';return}
      path='/files/logs/'+encodeURIComponent(tgt)+'/'+encodeURIComponent(sub)+'?lines=200';
    }else if(cat==='status'){
      path='/files/status/'+encodeURIComponent(tgt);
    }else if(cat==='report'){
      path='/files/report/'+encodeURIComponent(tgt);
    }else if(cat==='secrets'){
      path='/files/secrets/'+encodeURIComponent(tgt);
    }

    apiFetch(path,{timeout:30000}).then(function(d){
      var content=typeof d==='string'?d:(d.content||JSON.stringify(d,null,2));
      el.innerHTML='<pre>'+esc(content)+'</pre>';
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  });

  /* ═══════════════════════════════════════════
     CONTROL TAB
     ═══════════════════════════════════════════ */
  function loadControlPanel(){
    var el=document.getElementById('out-control');
    el.innerHTML='<span class="loading">loading VM and container state...</span>';

    Promise.all([
      apiFetch('/health/declared',{timeout:10000}).catch(function(){return{vms:{}}}),
      apiFetch('/health/deployed',{timeout:15000}).catch(function(){return{vms:{}}})
    ]).then(function(res){
      var declared=res[0],deployed=res[1];
      var dvms=declared.vms||{};
      var depVms=deployed.vms||{};
      var h='';

      for(var vmId in dvms){
        var vm=dvms[vmId];
        var dep=depVms[vmId]||{};
        var containers=dep.containers||[];
        var stMap={};
        for(var k=0;k<containers.length;k++)stMap[containers[k].name]=containers[k].state;

        h+='<div class="card">';
        h+='<div class="card-hdr">';
        h+='<h3>'+esc(vmId)+' <span class="badge '+(dep.running!=null?'badge-ok':'badge-off')+'">'+((dep.running||0))+' running</span></h3>';
        h+='<div class="flex-row">';
        h+='<button class="rbtn" data-vm-action="start" data-vm="'+esc(vmId)+'">Start VM</button>';
        h+='<button class="rbtn warn" data-vm-action="stop" data-vm="'+esc(vmId)+'">Stop VM</button>';
        h+='</div>';
        h+='</div>';

        var svcs=vm.services||{};
        var allContainers=[];
        for(var sn in svcs){
          var cs=svcs[sn];
          if(Array.isArray(cs))for(var i=0;i<cs.length;i++)allContainers.push(cs[i]);
        }
        for(var k=0;k<containers.length;k++){
          if(allContainers.indexOf(containers[k].name)===-1)allContainers.push(containers[k].name);
        }

        if(allContainers.length>0){
          h+='<table><tr><th>Container</th><th>State</th><th>Actions</th></tr>';
          for(var i=0;i<allContainers.length;i++){
            var cn=allContainers[i];
            var state=stMap[cn]||'not deployed';
            h+='<tr><td><code>'+esc(cn)+'</code></td>';
            h+='<td class="'+stClass(state)+'">'+esc(state)+'</td>';
            h+='<td class="flex-row">';
            h+='<button class="rbtn" style="padding:.15rem .4rem;font-size:.6rem" data-ct-action="start" data-ct-vm="'+esc(vmId)+'" data-ct-name="'+esc(cn)+'">Start</button>';
            h+='<button class="rbtn warn" style="padding:.15rem .4rem;font-size:.6rem" data-ct-action="stop" data-ct-vm="'+esc(vmId)+'" data-ct-name="'+esc(cn)+'">Stop</button>';
            h+='<button class="rbtn blue" style="padding:.15rem .4rem;font-size:.6rem" data-ct-action="restart" data-ct-vm="'+esc(vmId)+'" data-ct-name="'+esc(cn)+'">Restart</button>';
            h+='</td></tr>';
          }
          h+='</table>';
        }
        h+='</div>';
      }

      el.innerHTML=h;
    }).catch(function(e){el.innerHTML='<span class="st-err">'+esc(e.message)+'</span>'});
  }

  document.getElementById('out-control').addEventListener('click',function(e){
    var btn=e.target.closest('[data-vm-action]');
    if(btn){
      var vm=btn.dataset.vm, action=btn.dataset.vmAction;
      showConfirm('VM '+action.toUpperCase(), action+' VM "'+vm+'"? This affects all services on this VM.',function(){
        var el=btn.parentElement;
        el.innerHTML='<span class="loading">'+action+'ing...</span>';
        apiFetch('/vms/'+encodeURIComponent(vm)+'/'+action,{method:'POST',timeout:60000}).then(function(d){
          el.innerHTML='<span class="st-ok">'+action+' OK</span>';
          setTimeout(loadControlPanel,3000);
        }).catch(function(err){
          el.innerHTML='<span class="st-err">'+esc(err.message)+'</span>';
        });
      });
      return;
    }
    var ctBtn=e.target.closest('[data-ct-action]');
    if(ctBtn){
      var vm=ctBtn.dataset.ctVm, name=ctBtn.dataset.ctName, action=ctBtn.dataset.ctAction;
      showConfirm('Container '+action.toUpperCase(), action+' container "'+name+'" on '+vm+'?',function(){
        var row=ctBtn.closest('tr');
        var cells=row.querySelectorAll('td');
        if(cells[1])cells[1].innerHTML='<span class="loading">'+action+'ing...</span>';
        apiFetch('/vms/'+encodeURIComponent(vm)+'/containers/'+encodeURIComponent(name)+'/'+action,{method:'POST',timeout:30000}).then(function(d){
          if(cells[1])cells[1].innerHTML='<span class="st-ok">'+action+' OK</span>';
          setTimeout(loadControlPanel,2000);
        }).catch(function(err){
          if(cells[1])cells[1].innerHTML='<span class="st-err">'+esc(err.message)+'</span>';
        });
      });
    }
  });

  /* ═══ Init ═══ */
  loadHealthStatus();

  var controlLoaded=false;
  document.querySelector('[data-tab="control"]').addEventListener('click',function(){
    if(!controlLoaded){controlLoaded=true;loadControlPanel()}
  });

})();
