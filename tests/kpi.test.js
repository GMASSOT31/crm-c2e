// Recette des indicateurs : jeu de dossiers fictifs A à I du cahier des charges (27/10/2026). Lancer : node tests/kpi.test.js
const fs=require('fs'),assert=require('assert');
const src=fs.readFileSync(__dirname+'/../docs/index.html','utf8');
const code=src.slice(src.indexOf('/*KPI-BEGIN'),src.indexOf('/*KPI-END*/'));
const KPI=new Function(code+';return KPI')();
const NOW='2026-10-27T10:00:00Z',X='x',Y='y';
const profiles=[{id:X,role:'commercial',active:true},{id:Y,role:'commercial',active:true}];
const base={archived:false,opt_out:false,quality:'valide',stage:'a_contacter',assigned_to:null,received_on:'2026-10-10',received_at:null,received_precision:'jour',import_batch_id:null,rdv_on:null,rdv_origin:null,quote_ref:null,sale_on:null,sale_amount:null,sale_vat:null};
const R=(id,o)=>Object.assign({},base,{id},o);
const reqs=[
 R(1,{assigned_to:X}),                                                                                   // A
 R(2,{assigned_to:X,stage:'rdv_pris',rdv_on:'2026-10-14',rdv_origin:'confirme',received_at:'2026-10-10T08:00:00Z',received_precision:'minute'}), // B
 R(3,{assigned_to:X,stage:'vente_faite',sale_on:'2026-10-20',sale_amount:10000,sale_vat:'HT',received_at:'2026-10-11T08:00:00Z',received_precision:'minute'}), // C
 R(4,{quality:'doublon',assigned_to:null}),                                                              // D
 R(5,{quality:'a_verifier'}),                                                                            // E
 R(6,{stage:'cloture_sans_vente'}),                                                                      // F
 R(7,{}),                                                                                                // G
 R(8,{assigned_to:Y,stage:'rdv_pris',rdv_origin:'import',received_on:null,received_precision:null,import_batch_id:1}), // H
 R(9,{quality:'spam'})];                                                                                 // I
const acts=[{request_id:2,type:'contact',at:'2026-10-10T09:00:00Z'},{request_id:2,type:'appointment',at:'2026-10-10T09:05:00Z'},
 {request_id:3,type:'contact',at:'2026-10-11T10:00:00Z'},{request_id:3,type:'sale',at:'2026-10-20T10:00:00Z'}];
const ctx={reqs,acts,tasks:[],profiles,now:NOW},K=KPI.compute(ctx,{from:'2026-10-01',to:'2026-10-27'});
const ids=l=>l.map(r=>r.id).sort().join(',');
let n=0;const t=(nom,f)=>{f();n++};
t('reçus 8',()=>assert.strictEqual(K.recus.length,8));
t('exploitables validés 5 (A B C F G)',()=>assert.strictEqual(ids(K.valides),'1,2,3,6,7'));
t('à vérifier 1 (E)',()=>assert.strictEqual(ids(K.averifier),'5'));
t('doublon + spam 2',()=>assert.strictEqual(ids(K.exclus),'4,9'));
t('ouverts non attribués 2 (E G)',()=>assert.strictEqual(ids(K.nonAttribues),'5,7'));
t('clôturé non attribué 1 (F)',()=>assert.strictEqual(ids(K.cloturesNonAttribues),'6'));
t('non traité attribué 1 (A)',()=>assert.strictEqual(ids(K.nonTraites),'1'));
t('H : sans date de réception, présenté à part',()=>{assert.strictEqual(ids(K.sansDate),'8');assert.strictEqual(ids(K.nonTraitesReprise),'8');assert.strictEqual(ids(K.rdvADater),'8')});
t('RDV : B seul, 20 %',()=>{assert.strictEqual(ids(K.rdv),'2');assert.strictEqual(K.tRdv,20)});
t('vente : C seul, 20 % ; C sans RDV inventé',()=>{assert.strictEqual(ids(K.ventesCohorte),'3');assert.strictEqual(K.tVente,20)});
t('réactivité 90 min sur 2 dossiers',()=>{assert.strictEqual(K.reactiviteMin,90);assert.strictEqual(K.reactiviteN,2)});
t('CA HT 10 000, TTC 0, panier séparé',()=>{assert.strictEqual(K.caHT,10000);assert.strictEqual(K.caTTC,0);assert.strictEqual(K.panierTTC,null)});
// T02 : période vide, dates inconnues, heure de Paris
t('période vide : tout à zéro, taux non calculables',()=>{const E=KPI.compute(ctx,{from:'2026-01-01',to:'2026-01-31'});assert.strictEqual(E.recus.length,0);assert.strictEqual(E.tRdv,null);assert.strictEqual(E.reactiviteMin,null);assert.strictEqual(E.sansDate.length,1)});
t('réception tard le dernier jour (heure de Paris) reste dans la période',()=>{const c2=Object.assign({},ctx,{reqs:[R(20,{received_at:'2026-10-26T23:30:00Z',received_on:null,received_precision:'minute'})]});assert.strictEqual(KPI.compute(c2,{from:'2026-10-27',to:'2026-10-27'}).recus.length,1);assert.strictEqual(KPI.compute(c2,{from:'2026-10-26',to:'2026-10-26'}).recus.length,0)});
// T04 : deux RDV sur un même dossier ne comptent qu'une fois
t('deux RDV, un seul dossier',()=>{const c2=Object.assign({},ctx,{acts:acts.concat([{request_id:2,type:'appointment',at:'2026-10-12T09:00:00Z'}])});assert.strictEqual(KPI.compute(c2,{from:'2026-10-01',to:'2026-10-27'}).rdv.length,1)});
// RDV importé sans validation : pas de RDV confirmé, pas de taux > 100 %
t('RDV importé non validé reste à part',()=>{const c2=Object.assign({},ctx,{reqs:[R(30,{quality:'a_verifier',stage:'rdv_pris',rdv_origin:'import',import_batch_id:1})]});const k=KPI.compute(c2,{from:'2026-10-01',to:'2026-10-27'});assert.strictEqual(k.rdv.length,0);assert.strictEqual(k.rdvImportesNonValides.length,1);assert.strictEqual(k.tRdv,null)});
// T13 : montant nul ≠ montant absent ; HT et TTC séparés
t('ventes sans montant / montant nul / TTC',()=>{const v=(id,a,vat)=>R(id,{stage:'vente_faite',sale_on:'2026-10-20',sale_amount:a,sale_vat:vat});const c2=Object.assign({},ctx,{reqs:[v(40,null,null),v(41,0,'HT'),v(42,1200,'TTC'),v(43,800,'HT')]});const k=KPI.compute(c2,{from:'2026-10-01',to:'2026-10-27'});assert.deepStrictEqual([k.sansMontant,k.montantNul,k.caHT,k.caTTC],[1,1,800,1200])});
// T08 : un rappel terminé n'est plus en retard ; un mail n'est pas un retard
t('retards',()=>{const tk=[{request_id:1,kind:'callback',due_at:'2026-10-26T10:00:00Z',status:'open'},{request_id:2,kind:'callback',due_at:'2026-10-26T10:00:00Z',status:'done'},{request_id:3,kind:'mail',due_at:'2026-10-26T10:00:00Z',status:'open'}];assert.strictEqual(ids(KPI.compute(Object.assign({},ctx,{tasks:tk}),{from:'2026-10-01',to:'2026-10-27'}).enRetard),'1')});
console.log('KPI : '+n+' contrôles réussis');
