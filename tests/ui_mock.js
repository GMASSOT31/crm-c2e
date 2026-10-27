// Essai d'affichage avec un client Supabase simulé (le bac à sable n'atteint pas Supabase). Lancer : node tests/ui_mock.js
const { chromium } = require('playwright');
const fs = require('fs');
const html = fs.readFileSync(__dirname + '/../docs/index.html', 'utf8');
const stub = `
window.__DB = {
 profiles:[{id:'adm',full_name:'Admin Test',role:'admin',active:true},{id:'x',full_name:'Commercial X',role:'commercial',active:true},{id:'y',full_name:'Commercial Y',role:'commercial',active:true}],
 sources:[{id:1,name:'Leads Dualsun',active:true}], work_types:[{id:1,name:'Photovoltaïque',active:true}],
 requests:[], duplicate_reviews:[], activities:[], tasks:[], feedback:[], zone_rules:[{kind:'postal',value:'31',label:'Commercial X',active:true,user_id:'x'},{kind:'postal',value:'31200',label:'Commercial Y',active:true,user_id:'y'},{kind:'postal',value:'971',label:'Commercial X',active:true,user_id:'x'},{kind:'city',value:'albi',label:'Sans Compte',active:true,user_id:null}]};
(function(){var n=1;function R(o){var base={contact_id:n,source_id:1,sources:{name:'Leads Dualsun'},request_work_types:[{work_types:{name:'Photovoltaïque'}}],quality:'valide',stage:'a_contacter',archived:false,opt_out:false,version:1,created_at:'2026-10-26T13:00:00Z',received_on:null,received_at:null,import_batch_id:null,alerts:[],assigned_to:null};var r=Object.assign(base,o);r.id=n;r.contacts={display_name:'Contact '+n,phone_raw:'0600000000',city:'Toulouse',postal_code:'31000'};n++;return r}
 var D=window.__DB;
 // 3 dossiers importés sans date de réception (comme en production), 1 daté, 1 RDV importé sans date
 D.requests=[R({quality:'a_verifier',import_batch_id:1,imported_at:'2026-10-26T13:00:00Z'}),R({quality:'a_verifier',import_batch_id:1,imported_at:'2026-10-26T13:00:00Z',assigned_to:'x'}),
   R({quality:'valide',import_batch_id:1,imported_at:'2026-10-26T13:00:00Z',assigned_to:'x',stage:'rdv_pris',rdv_origin:'import'}),
   R({quality:'valide',received_on:'2026-10-20',received_precision:'jour',assigned_to:'x'}),R({quality:'valide',received_on:'2026-10-21',assigned_to:'y',stage:'vente_faite',sale_on:'2026-10-25',sale_amount:5000,sale_vat:'HT'}),R({quality:'a_verifier',alerts:['Adresse email douteuse']})];
 var tm=new Date(Date.now()+864e5).toISOString().slice(0,10);D.requests.push(R({quality:'valide',received_on:'2026-10-22',assigned_to:'adm',stage:'rdv_pris',rdv_on:tm,rdv_time:'10:00:00',rdv_origin:'confirme',rdv_status:'planifie'}));D.requests.push(R({quality:'valide',received_on:'2026-10-15',assigned_to:'adm',stage:'devis_realise',quote_ref:'D-77'}),R({quality:'valide',received_on:'2026-10-16',assigned_to:'adm',stage:'vente_faite',sale_on:'2026-10-20',sale_amount:0,sale_vat:'HT'}));
 D.tasks=[{id:1,request_id:4,kind:'callback',due_at:'2026-10-26T09:00:00Z',status:'open',all_day:false}];
 D.requests.forEach(function(r){r.contacts.email_raw=r.id===4?'a@exemple.test':''; if(r.id===6)r.contacts.phone_raw='';});
 function q(t){var f=[],lim=null;var o={select:function(){return o},eq:function(c,v){f.push([c,v]);return o},is:function(){return o},order:function(){return o},range:function(a,b){return o},
  maybeSingle:function(){return Promise.resolve({data:(window.__DB[t]||[]).filter(function(r){return f.every(function(x){return r[x[0]]===x[1]})})[0]||null,error:null})},
  then:function(a,b){return Promise.resolve({data:(window.__DB[t]||[]).filter(function(r){return f.every(function(x){return r[x[0]]===x[1]})}),error:null}).then(a,b)}};return o}
 window.supabase={createClient:function(){return{from:q,rpc:function(fn,a){if(fn==='set_quality'){window.__DB.requests.forEach(function(r){if(r.id===a.p_request)r.quality=a.p_quality})}if(fn==='admin_account_states'){return Promise.resolve({data:[{id:'x',confirmed:false,last_sign_in:null,must_change:true},{id:'y',confirmed:true,last_sign_in:null,must_change:true}],error:null})}if(fn==='simulate_zones'){return Promise.resolve({data:window.__DB.requests.filter(function(r){return !r.assigned_to&&r.stage!=='vente_faite'}).map(function(r,i){return i%2?{id:r.id,status:'non_couvert',reason:'aucune'}:{id:r.id,status:'ok',owner:'x'}}),error:null})}if(fn==='assign_requests_report'){return Promise.resolve({data:{assigned:a.p_request_ids.length-1,already:0,failed:[{id:a.p_request_ids[0],reason:'INCOMPLET'}]},error:null})}return Promise.resolve({data:null,error:null})},functions:{invoke:function(n,o){window.__calls=(window.__calls||[]).concat([o.body]);if(/chef/.test(o.body.name||''))return Promise.resolve({error:{context:{json:function(){return Promise.resolve({error:'x'})}}}});return Promise.resolve({data:o.body.temp?{password:'Zq7mK2pLw9RtXe',id:'n1'}:{link:'https://exemple.test/lien',id:'n2'},error:null})}},auth:{getSession:function(){return Promise.resolve({data:{session:{user:{id:'adm',user_metadata:{}}}}})},signOut:function(){return Promise.resolve({})},onAuthStateChange:function(){return{data:{subscription:{unsubscribe:function(){}}}}}}}}};
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
  // --- QUA02 : doublons ---
  await p.click('#tabs button[data-v=contacts]'); await p.click('#tbl a[data-act=open] >> nth=0'); await p.waitForSelector('.sheet'); const dp = await p.innerText('.sheet');
  ok(/doublons/i.test(dp) && /garder distincts/i.test(dp) && /code postal et ville/i.test(dp), 'Doublons : tableau de comparaison et décisions proposés');
  await p.click('button[data-act=dupdo][data-d=distinct] >> nth=0'); ok(/justification est obligatoire/.test(await p.innerText('#app')), 'Garder distincts sans justification : refusé');
  await p.click('button[data-act=dupdo][data-d=doublon] >> nth=0'); ok(/sera marqué doublon/.test(await p.innerText('#confirm')) && /Rien n.est supprimé/.test(await p.innerText('#confirm')), 'Confirmer un doublon : demande de confirmation, rien supprimé');
  await p.click('button[data-act=confirmno]'); await p.click('button[data-act=close]');
  // --- ENT02 : ajout et import ---
  await p.click('#tabs button[data-v=add]'); await p.fill('#paste', 'Nom Dubois\nPrénom Laura\nTéléphone 06 12 34 56 78\nAdresse e-mail laura.dubois@exemple.test\nCode Postal 31200\nVille Toulouse'); await p.click('button[data-act=parse]');
  ok(await p.locator('input[name=pw]').count() >= 1, 'Ajout : types de travaux en cases à cocher');
  ok(/Attribuable à un commercial : oui/.test(await p.innerText('#p_ready')), 'Ajout : état du brouillon (attribuable) affiché');
  await p.screenshot({ path: process.env.SHOT_ADD || '/tmp/ui_add.png' });
  await p.fill('#p_email', 'pas-un-email'); ok(/Adresse email invalide/.test(await p.innerText('#e_email')) && (await p.getAttribute('#p_email', 'aria-invalid')) === 'true', 'Ajout : erreur affichée sous le champ, saisie conservée');
  await p.fill('#p_cp', '312'); ok(/5 chiffres/.test(await p.innerText('#e_cp')), 'Ajout : code postal invalide signalé');
  await p.fill('#p_name', ''); await p.fill('#p_phone', ''); await p.fill('#p_email', ''); ok(/rien à enregistrer/.test(await p.innerText('#p_ready')), 'Ajout : rien à enregistrer sans nom ni contact');
  await p.click('button[data-act=addmode][data-m=file]');
  await p.setInputFiles('#ifile', { name: 'demandes.csv', mimeType: 'text/csv', buffer: Buffer.from('Nom;Téléphone;Email;Code postal;Date de réception\nMARTIN Paul;0612345678;paul@exemple.test;1000;2026-10-12\nTOTAL;;;;\nDURAND;;;31000;\n', 'utf-8') });
  await p.waitForSelector('text=Type d\'import'); const im1 = await p.innerText('#app');
  ok(/Correspondance des colonnes/.test(im1) && /Lignes lues : 3 = à créer ou liées 1 \+ ignorées 1 \+ rejetées 1/.test(im1), 'Import : aperçu des colonnes et bilan réconcilié (lues = créées + ignorées + rejetées)');
  ok(/Reprise historique/.test(im1) && /Aucune relance/.test(im1), 'Import : effets de la reprise historique expliqués');
  await p.check('input[name=imode][value=new]'); const im2 = await p.innerText('#app');
  ok(/sont ignorées/.test(im2) && /Date de réception commune/.test(im2), 'Import : nouvelles demandes, colonnes historiques ignorées et date commune facultative');
  // --- RAP01 : devis, ventes, relances ---
  await p.click('#tabs button[data-v=contacts]'); await p.click('button[data-act=resetf]'); await p.selectOption('#fpg', '100');
  await p.click('#tbl tr:has-text("Devis réalisé") a[data-act=open] >> nth=0'); await p.waitForSelector('.sheet'); const dv = await p.innerText('.sheet');
  ok(/suite conseillée/i.test(dv) && /Programmer la relance du devis/.test(dv), 'Devis réalisé : la relance du devis est proposée');
  await p.click('button[data-act=form][data-k=relance]'); await p.click('button[data-act=saveform][data-k=relance]'); ok(/date de la relance/.test(await p.innerText('#app')), 'Relance sans date : refusée');
  await p.click('button[data-act=close]');
  await p.click('#tbl tr:has-text("Vente faite") a[data-act=open] >> nth=-1'); await p.waitForSelector('.sheet'); const vt = await p.innerText('.sheet');
  ok(/vente enregistrée/i.test(vt) && /montant nul/.test(vt) && /Corriger la vente/.test(vt), 'Vente : montant nul distingué du montant absent, correction possible');
  await p.click('button[data-act=close]');
  // --- ATT02 / KPI05 / DAT03 ---
  await p.click('#tabs button[data-v=team]'); await p.click('button[data-act=teamtab][data-v=zones]'); const zc = await p.innerText('#app');
  ok(/chevauchement/i.test(zc) && /sans compte/i.test(zc) && /3 chiffres/.test(zc), 'Zones : chevauchements, règles sans compte et codes à 3 chiffres signalés');
  await p.click('#tabs button[data-v=assign]'); await p.click('button[data-act=simzones]'); ok(/Aucune zone ne correspond/.test(await p.innerText('#app')), 'Simulation : cause « aucune zone » expliquée');
  await p.click('#tabs button[data-v=stats]'); await p.click('button[data-act=per][data-v="30"]'); const pa = (await p.innerText('#app')).match(/Période appliquée : du [^.]*\./)[0];
  await p.click('#tabs button[data-v=dash]'); const pb = (await p.innerText('#app')).match(/Période appliquée : du [^.]*\./)[0];
  ok(pa === pb && /Tout l.historique daté/.test(await p.innerText('#app')), 'Périodes : la même période s\'applique à Pilotage et à Statistiques');
  await p.click('button[data-act=per][data-v=custom]'); ok(await p.locator('#per_from').count() === 1, 'Périodes : dates précises disponibles');
  await p.click('#tabs button[data-v=home]'); await p.click('.cnt >> nth=0'); ok(/Retour à « Accueil »/.test(await p.innerText('#app')), 'Carte : la liste ouverte propose un retour à la vue d\'origine');
  await p.click('button[data-act=backview]'); ok(/Bonjour|Accueil/.test(await p.innerText('#app')), 'Retour à l\'Accueil');
  await p.click('#tabs button[data-v=add]'); await p.click('button[data-act=addmode][data-m=paste]'); await p.fill('#paste', 'Nom Dubois\nPrénom Laura\nTéléphone 0612345678'); await p.click('button[data-act=parse]');
  ok(await p.inputValue('#p_last') === 'Dubois' && await p.inputValue('#p_first') === 'Laura' && await p.inputValue('#p_name') === 'Dubois Laura', 'Noms : nom, prénom et nom d\'affichage séparés');
  await p.fill('#p_first', 'Lauren'); ok(await p.inputValue('#p_name') === 'Dubois Lauren', 'Noms : le nom d\'affichage suit tant qu\'il n\'est pas modifié à la main');
  await p.fill('#p_name', 'DUBOIS SARL'); await p.fill('#p_first', 'Lau'); ok(await p.inputValue('#p_name') === 'DUBOIS SARL', 'Noms : une raison sociale saisie à la main n\'est pas écrasée');
  // --- Comptes : ajout de personnel ---
  await p.click('#tabs button[data-v=team]'); await p.click('button[data-act=teamtab][data-v=users]'); const us = await p.innerText('#app');
  ok(/Invitation non acceptée/.test(us) && /Jamais connecté/.test(us), 'Comptes : invitation non acceptée et jamais connecté repérés');
  ok(await p.isChecked('input[name=npm][value=temp]'), 'Ajout : mot de passe provisoire proposé par défaut');
  await p.fill('#np_email', 'Marie.Test@Exemple.fr'); await p.fill('#np_name', 'Marie TEST'); await p.selectOption('#np_role', 'secretariat'); await p.click('button[data-act=invite]'); await p.waitForSelector('text=Mot de passe provisoire :');
  const ac = await p.innerText('#app'); ok(/marie\.test@exemple\.fr/.test(ac) && /Zq7mK2pLw9RtXe/.test(ac), 'Ajout : identifiant (email) et mot de passe provisoire affichés une seule fois');
  ok((await p.evaluate(() => window.__calls.slice(-1)[0].temp)) === true, 'Ajout : la création demande bien un mot de passe provisoire');
  await p.check('input[name=npm][value=link]'); await p.fill('#np_email', 'lien@exemple.fr'); await p.fill('#np_name', 'Lien TEST'); await p.click('button[data-act=invite]'); await p.waitForSelector('#invlink');
  ok(/Tant que ce lien n.est pas ouvert/.test(await p.innerText('#app')), 'Ajout par lien : prévenu qu\'aucun mot de passe n\'existe avant ouverture du lien');
  await p.fill('#bulk', 'a@exemple.fr ; Anne Une ; secrétaire\nb@exemple.fr ; Bob Deux ; Commercial\nc@exemple.fr ; Chef Trois ; chef'); await p.click('button[data-act=bulkcreate]'); await p.waitForSelector('text=À noter maintenant');
  const roles = await p.evaluate(() => window.__calls.filter(c => c.temp && /^[abc]@/.test(c.email)).map(c => c.email[0] + ':' + c.role).join(','));
  ok(roles === 'a:secretariat,b:commercial', 'Création en lot : « secrétaire » reconnu, rôle inconnu refusé au lieu d\'être mis en commercial (obtenu ' + roles + ')');
  ok(/inconnu/.test(await p.innerText('#app')), 'Création en lot : rôle inconnu signalé');
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
