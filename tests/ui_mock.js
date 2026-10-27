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
 var tm=new Date(Date.now()+864e5).toISOString().slice(0,10);D.requests.push(R({quality:'valide',received_on:'2026-10-22',assigned_to:'adm',stage:'rdv_pris',rdv_on:tm,rdv_time:'10:00:00',rdv_origin:'confirme',rdv_status:'planifie'}));D.tasks=[{id:1,request_id:4,kind:'callback',due_at:'2026-10-26T09:00:00Z',status:'open',all_day:false}];
 D.requests.forEach(function(r){r.contacts.email_raw=r.id===4?'a@exemple.test':''; if(r.id===6)r.contacts.phone_raw='';});
 function q(t){var f=[],lim=null;var o={select:function(){return o},eq:function(c,v){f.push([c,v]);return o},order:function(){return o},range:function(a,b){return o},
  maybeSingle:function(){return Promise.resolve({data:(window.__DB[t]||[]).filter(function(r){return f.every(function(x){return r[x[0]]===x[1]})})[0]||null,error:null})},
  then:function(a,b){return Promise.resolve({data:(window.__DB[t]||[]).filter(function(r){return f.every(function(x){return r[x[0]]===x[1]})}),error:null}).then(a,b)}};return o}
 window.supabase={createClient:function(){return{from:q,rpc:function(fn,a){if(fn==='set_quality'){window.__DB.requests.forEach(function(r){if(r.id===a.p_request)r.quality=a.p_quality})}if(fn==='simulate_zones'){return Promise.resolve({data:window.__DB.requests.filter(function(r){return !r.assigned_to&&r.stage!=='vente_faite'}).map(function(r,i){return i%2?{id:r.id,status:'non_couvert'}:{id:r.id,status:'ok',owner:'x'}}),error:null})}if(fn==='assign_requests_report'){return Promise.resolve({data:{assigned:a.p_request_ids.length-1,already:0,failed:[{id:a.p_request_ids[0],reason:'INCOMPLET'}]},error:null})}return Promise.resolve({data:null,error:null})},auth:{getSession:function(){return Promise.resolve({data:{session:{user:{id:'adm',user_metadata:{}}}}})},signOut:function(){return Promise.resolve({})},onAuthStateChange:function(){return{data:{subscription:{unsubscribe:function(){}}}}}}}}};
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
  // --- Lot 3B : agenda, rendez-vous, actions, notes, vues rapides ---
  await p.click('#tabs button[data-v=agenda]'); const ag = await p.innerText('#app');
  ok(/Rendez-vous/.test(ag) && /\(1\)/.test(ag), 'Agenda : vues avec compteurs');
  await p.click('button[data-act=agv][data-v=dater]'); ok(/À dater/.test(await p.innerText('#app')), 'Agenda : RDV à dater séparé');
  await p.click('button[data-act=agv][data-v=tous]'); await p.click('#app tr.click:has-text("planifié")'); await p.waitForSelector('.sheet'); const rv = await p.innerText('.sheet');
  ok(/Rendez-vous/.test(rv) && /planifié/.test(rv) && /Reporter ou modifier/.test(rv), 'Fiche : carte Rendez-vous (statut, report)');
  ok(/Ajouter une note/.test(rv) && /Contact établi/.test(rv), 'Fiche : notes et bouton Contact établi');
  await p.screenshot({ path: process.env.SHOT_RDV || '/tmp/ui_rdv.png' });
  await p.click('button[data-act=form][data-pre=annule]'); await p.click('button[data-act=saveform][data-k=rdvst]'); ok(/suite|rappel/i.test(await p.innerText('#app')), 'RDV annulé sans rappel refusé');
  await p.click('button[data-act=close]');
  await p.click('#tabs button[data-v=contacts]'); const qv = await p.innerText('#app');
  ok(/Rappels en retard \(1\)/.test(qv) && /Sans prochaine action/.test(qv), 'Vues rapides avec compteurs');
  await p.click('button[data-act=qvw][data-v=late]'); ok(/1 dossier/.test(await p.innerText('#tbl')), 'Vue rapide : rappels en retard');
  await p.click('button[data-act=resetf]');
  // --- Lot 5 : extraction du nom (T03), clavier, saisie non enregistrée, mobile ---
  await p.click('#tabs button[data-v=add]');
  const cas = [['Nom Dubois\nPrénom Laura\nTéléphone 06 12 34 56 78\nAdresse e-mail laura.dubois@exemple.test','Dubois Laura'],['Nom et prénom : Dubois Laura\nTéléphone 0612345678','Dubois Laura'],['Nom complet\tÉloïse N’Diaye-Martin\nTéléphone 0612345678','Éloïse N’Diaye-Martin'],['Nom du formulaire: Formulaire estimation de votre projet sur le site\nTéléphone 0612345678','']];
  for (const [txt, want] of cas) { await p.fill('#paste', txt); await p.click('button[data-act=parse]'); const v = await p.inputValue('#p_name').catch(() => ''); ok(v === want, 'Extraction du nom : « ' + txt.split('\n')[0].slice(0, 34) + ' » → « ' + want + ' » (obtenu « ' + v + ' »)'); }
  await p.click('#tabs button[data-v=contacts]'); await p.focus('#tbl a[data-act=open]'); await p.keyboard.press('Enter'); await p.waitForSelector('.sheet');
  ok(await p.evaluate(() => document.activeElement && document.activeElement.getAttribute('data-act') === 'close'), 'Clavier : le dossier s\'ouvre avec Entrée et le focus va sur « Fermer »');
  await p.fill('#nt_text', 'note en cours'); await p.keyboard.press('Escape'); ok(/Fermer sans enregistrer/.test(await p.innerText('#confirm')), 'Saisie non enregistrée : demande de confirmation à la fermeture');
  await p.keyboard.press('Escape'); ok(await p.inputValue('#nt_text') === 'note en cours', 'Échap sur la confirmation : la saisie est conservée');
  await p.click('button[data-act=close]'); await p.click('button[data-act=confirmyes]'); ok(!(await p.$('.sheet')), 'Après confirmation, la fiche se ferme');
  for (const w of [360, 390, 768, 1366]) { await p.setViewportSize({ width: w, height: 800 }); for (const v of ['home', 'contacts', 'agenda', 'add', 'assign', 'stats', 'dash', 'team', 'fb']) { await p.click('#tabs button[data-v=' + v + ']').catch(() => {}); const ov = await p.evaluate(() => document.documentElement.scrollWidth - window.innerWidth); if (ov > 1) { ok(false, 'Débordement horizontal à ' + w + ' px sur ' + v + ' (' + ov + ' px) : ' + await p.evaluate(() => { const W = window.innerWidth; return [...document.querySelectorAll('#app *')].filter(e => e.getBoundingClientRect().right > W + 1).slice(0, 3).map(e => e.tagName + '#' + e.id + '.' + e.className).join(' | '); })); } } }
  ok(true, 'Largeurs 360 / 390 / 768 / 1366 : pas de défilement horizontal de la page'); await p.setViewportSize({ width: 390, height: 800 });
  // --- Lot 4 : attribution en masse et Équipe ---
  await p.click('#tabs button[data-v=assign]'); const as1 = await p.innerText('#app');
  ok(/Dossiers à attribuer ou à réattribuer/.test(as1) && /Simulation des zones/.test(as1), 'Attribution : liste filtrable et simulation des zones');
  await p.click('button[data-act=selpage]'); ok(/\d+ dossier\(s\) sélectionné/.test(await p.innerText('#asbar')), 'Attribution : barre de sélection visible');
  await p.click('button[data-act=simzones]'); ok(/attribuables/.test(await p.innerText('#app')), 'Simulation : résultat sans rien modifier');
  await p.selectOption('#atarget', 'x'); await p.click('button[data-act=aspreview]'); const pv = await p.innerText('#app');
  ok(/Prévisualisation/.test(pv) && /→/.test(pv), 'Prévisualisation : charge avant → après');
  await p.click('button[data-act=doassign]'); await p.click('button[data-act=confirmyes]'); await p.waitForTimeout(300);
  const rp = await p.innerText('#app'); ok(/Résultat de l.attribution/.test(rp) && /incomplet/i.test(rp), 'Rapport : succès et échecs par motif');
  await p.click('#tabs button[data-v=team]'); ok(/Utilisateurs et accès/.test(await p.innerText('#app')) && /Secteurs et attribution automatique/.test(await p.innerText('#app')) && /Reprise historique/.test(await p.innerText('#app')), 'Équipe : trois sous-rubriques');
  await p.click('button[data-act=teamtab][data-v=zones]'); ok(/Zones d.attribution automatique/.test(await p.innerText('#app')), 'Équipe : secteurs');
  await p.click('button[data-act=teamtab][data-v=users]'); await p.click('button[data-act=toggleu] >> nth=1'); ok(/dossier\(s\) ouvert\(s\) passeront/.test(await p.innerText('#confirm')), 'Désactivation : conséquences expliquées');
  await p.click('button[data-act=confirmno]');
  await p.click('#tabs button[data-v=stats]'); const st = await p.innerText('#app');
  ok(/Date de réception|Sans date de réception/.test(st) && /non calculable/i.test(st), 'Pilotage : réactivité/taux non calculables sans données');
  ok(/1 vente/.test(st) || /vente\(s\)/.test(st), 'Pilotage : ventes datées');
  await p.click('#tabs button[data-v=dash]'); await p.waitForSelector('.kpis'); const ds = await p.innerText('#app');
  ok(/Chiffre d.affaires HT/.test(ds) && /Non calculable/.test(ds), 'Statistiques : CA HT et réactivité non calculable');
  await p.click('#tabs button[data-v=dash]'); await p.click('button[data-act=dashdemo]'); await p.click('#tabs button[data-v=contacts]');
  ok(/Données fictives/.test(await p.innerText('#app')), 'Mode exemple : bandeau « Données fictives » sur les autres écrans'); await p.click('button[data-act=dashquit]'); ok(!/Données fictives/.test(await p.innerText('#app')), 'Mode exemple : sortie évidente');
  ok(errs.length === 0, 'aucune erreur JavaScript' + (errs.length ? ' : ' + errs.join(' | ') : ''));
  await p.screenshot({ path: process.env.SHOT || '/tmp/ui_stats.png', fullPage: false }); await b.close();
})();
