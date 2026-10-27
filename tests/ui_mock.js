// Essai d'affichage avec un client Supabase simulé (le bac à sable n'atteint pas Supabase). Lancer : node tests/ui_mock.js
const { chromium } = require('playwright');
const fs = require('fs');
const html = fs.readFileSync(__dirname + '/../docs/index.html', 'utf8');
const stub = `
window.__DB = {
 profiles:[{id:'adm',full_name:'Admin Test',role:'admin',active:true},{id:'x',full_name:'Commercial X',role:'commercial',active:true},{id:'y',full_name:'Commercial Y',role:'commercial',active:true}],
 sources:[{id:1,name:'Leads Dualsun',active:true}], work_types:[{id:1,name:'Photovoltaïque',active:true}],
 requests:[], activities:[], tasks:[], feedback:[], zone_rules:[]};
(function(){var n=1;function R(o){var base={contact_id:n,source_id:1,sources:{name:'Leads Dualsun'},request_work_types:[{work_types:{name:'Photovoltaïque'}}],quality:'valide',stage:'a_contacter',archived:false,opt_out:false,version:1,created_at:'2026-10-26T13:00:00Z',received_on:null,received_at:null,import_batch_id:null,alerts:[],assigned_to:null};var r=Object.assign(base,o);r.id=n;r.contacts={display_name:'Contact '+n,phone_raw:'0600000000',city:'Toulouse',postal_code:'31000'};n++;return r}
 var D=window.__DB;
 // 3 dossiers importés sans date de réception (comme en production), 1 daté, 1 RDV importé sans date
 D.requests=[R({quality:'a_verifier',import_batch_id:1,imported_at:'2026-10-26T13:00:00Z'}),R({quality:'a_verifier',import_batch_id:1,imported_at:'2026-10-26T13:00:00Z',assigned_to:'x'}),
   R({quality:'valide',import_batch_id:1,imported_at:'2026-10-26T13:00:00Z',assigned_to:'x',stage:'rdv_pris',rdv_origin:'import'}),
   R({quality:'valide',received_on:'2026-10-20',received_precision:'jour',assigned_to:'x'}),R({quality:'valide',received_on:'2026-10-21',assigned_to:'y',stage:'vente_faite',sale_on:'2026-10-25',sale_amount:5000,sale_vat:'HT'}),R({quality:'a_verifier',alerts:['Adresse email douteuse']})];
 D.requests.forEach(function(r){r.contacts.email_raw=r.id===4?'a@exemple.test':''; if(r.id===6)r.contacts.phone_raw='';});
 function q(t){var f=[],lim=null;var o={select:function(){return o},eq:function(c,v){f.push([c,v]);return o},order:function(){return o},range:function(a,b){return o},
  maybeSingle:function(){return Promise.resolve({data:(window.__DB[t]||[]).filter(function(r){return f.every(function(x){return r[x[0]]===x[1]})})[0]||null,error:null})},
  then:function(a,b){return Promise.resolve({data:(window.__DB[t]||[]).filter(function(r){return f.every(function(x){return r[x[0]]===x[1]})}),error:null}).then(a,b)}};return o}
 window.supabase={createClient:function(){return{from:q,rpc:function(fn,a){if(fn==='set_quality'){window.__DB.requests.forEach(function(r){if(r.id===a.p_request)r.quality=a.p_quality})}return Promise.resolve({data:null,error:null})},auth:{getSession:function(){return Promise.resolve({data:{session:{user:{id:'adm',user_metadata:{}}}}})},signOut:function(){return Promise.resolve({})},onAuthStateChange:function(){return{data:{subscription:{unsubscribe:function(){}}}}}}}}};
})();`;
(async () => {
  const b = await chromium.launch(); const p = await b.newPage({ viewport: { width: 390, height: 800 } });
  const errs = []; p.on('pageerror', e => errs.push(e.message));
  await p.route('**/*', r => { const u = r.request().url();
    if (u.includes('supabase-js')) return r.fulfill({ contentType: 'text/javascript', body: stub });
    if (u.includes('xlsx')) return r.fulfill({ contentType: 'text/javascript', body: 'window.XLSX={};' });
    if (u.startsWith('file:') || u.includes('fonts.')) return r.abort();
    if (u === 'https://example.test/') return r.fulfill({ contentType: 'text/html', body: html }); return r.abort(); });
  await p.goto('https://example.test/'); await p.waitForSelector('#tabs button');
  const home = await p.innerText('#app'); console.log('--- ACCUEIL ---\n' + home.slice(0, 700));
  const ok = (c, m) => { if (!c) { console.error('ÉCHEC : ' + m); process.exitCode = 1 } else console.log('OK : ' + m) };
  ok(/Sans date de réception\s*\n?/.test(home) && /4\s*\n?\s*Sans date|Sans date de réception/.test(home), 'Accueil affiche « Sans date de réception »');
  // --- Lot 3A : liste, alertes, file « à vérifier » ---
  await p.click('#tabs button[data-v=contacts]'); const ls = await p.innerText('#app');
  ok(/Anomalie bloquante/.test(ls) && /Doublon possible/.test(ls) && /Information incomplète/.test(ls), 'Liste : badges Anomalie bloquante / Doublon possible / Information incomplète');
  ok(/Sans prochaine action/.test(ls) && /RDV à dater|RDV pris · à dater/.test(ls), 'Liste : « Sans prochaine action » et RDV à dater');
  await p.click('#fdet summary'); await p.selectOption('#fqa', 'bloquante'); ok(/1 sur 1|1–1 sur 1/.test(await p.innerText('#tbl')) || /1 dossier/.test(await p.innerText('#tbl')), 'Filtre qualité : anomalies bloquantes');
  await p.selectOption('#fqa', ''); await p.selectOption('#fpg', '15');
  await p.fill('#fq', 'zzzz'); const em = await p.innerText('#tbl'); ok(/Effacer la recherche/.test(em) && /Réinitialiser les filtres/.test(em), 'Recherche sans résultat : deux boutons distincts');
  await p.click('#tbl button[data-act=clearq]'); ok((await p.inputValue('#fq')) === '', 'Effacer la recherche vide le champ');
  await p.screenshot({ path: process.env.SHOT_LIST || '/tmp/ui_list.png' });
  await p.click('button[data-act=queue]'); await p.waitForSelector('.sheet'); const q1 = await p.innerText('.sheet');
  ok(/File « à vérifier » : dossier 1 sur 3/.test(q1), 'File à vérifier : dossier 1 sur 3');
  ok(/Coordonnées/.test(q1) && !/version/.test(q1), 'Fiche : « Coordonnées » sans « version »');
  await p.screenshot({ path: process.env.SHOT_FICHE || '/tmp/ui_fiche.png' });
  await p.click('button[data-act=qv][data-q=valide]'); await p.waitForTimeout(300); const q2 = await p.innerText('.sheet');
  ok(/dossier 2 sur 3/.test(q2), 'Après traitement, le dossier suivant s\'ouvre');
  await p.click('button[data-act=qstop]'); await p.click('button[data-act=close]');
  await p.click('#tabs button[data-v=stats]'); const st = await p.innerText('#app');
  ok(/Date de réception|Sans date de réception/.test(st) && /non calculable/i.test(st), 'Pilotage : réactivité/taux non calculables sans données');
  ok(/1 vente/.test(st) || /vente\(s\)/.test(st), 'Pilotage : ventes datées');
  await p.click('#tabs button[data-v=dash]'); await p.waitForSelector('.kpis'); const ds = await p.innerText('#app');
  ok(/Chiffre d.affaires HT/.test(ds) && /Non calculable/.test(ds), 'Statistiques : CA HT et réactivité non calculable');
  ok(errs.length === 0, 'aucune erreur JavaScript' + (errs.length ? ' : ' + errs.join(' | ') : ''));
  await p.screenshot({ path: process.env.SHOT || '/tmp/ui_stats.png', fullPage: false }); await b.close();
})();
