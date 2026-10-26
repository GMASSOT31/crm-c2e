import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.118.0';

// Envoie un e-mail au(x) super administrateur(s) quand un retour est déposé.
// Nécessite le secret RESEND_API_KEY (Supabase > Edge Functions > Secrets). Sans lui, la fonction ne fait rien.
const SITE = 'https://gmassot31.github.io/crm-c2e/';
const KINDS: Record<string, string> = { probleme: 'Problème', idee: 'Idée', question: 'Question', autre: 'Autre' };
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type' };
const reply = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, 'Content-Type': 'application/json' } });
const esc = (t: string) => t.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const url = Deno.env.get('SUPABASE_URL')!, anon = Deno.env.get('SUPABASE_ANON_KEY')!, svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const key = Deno.env.get('RESEND_API_KEY');
  const asUser = createClient(url, anon, { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
  const { data: u } = await asUser.auth.getUser();
  if (!u?.user) return reply({ error: 'Non connecté.' }, 401);
  let id: number;
  try { id = Number((await req.json()).id); } catch { return reply({ error: 'Requête illisible.' }, 400); }
  // l'auteur ne peut déclencher l'alerte que pour son propre retour (lecture soumise aux règles d'accès)
  const { data: fb } = await asUser.from('feedback').select('id,author,kind,message,page,created_at').eq('id', id).eq('author', u.user.id).maybeSingle();
  if (!fb) return reply({ error: 'Retour introuvable.' }, 404);
  if (!key) return reply({ sent: false, reason: 'non_configure' });
  const admin = createClient(url, svc);
  const { data: done } = await admin.from('feedback').select('notified_at').eq('id', id).maybeSingle();
  if (done?.notified_at) return reply({ sent: false, reason: 'deja_envoye' });
  const { data: sup } = await admin.from('profiles').select('id').eq('is_super', true).eq('active', true);
  const emails: string[] = [];
  for (const p of sup ?? []) { const { data } = await admin.auth.admin.getUserById(p.id); if (data?.user?.email) emails.push(data.user.email); }
  if (!emails.length) return reply({ sent: false, reason: 'aucun_destinataire' });
  const { data: author } = await admin.from('profiles').select('full_name,role').eq('id', fb.author).maybeSingle();
  const kind = KINDS[fb.kind] ?? 'Retour';
  const html = `<div style="font-family:Arial,sans-serif;max-width:560px">
<h2 style="margin:0 0 8px;color:#10201a">Nouveau retour : ${esc(kind)}</h2>
<p style="margin:0 0 12px;color:#5a6c62">De <b>${esc(author?.full_name ?? 'un membre de l\'équipe')}</b>${fb.page ? ' · écran « ' + esc(fb.page) + ' »' : ''}</p>
<div style="background:#f5f8f4;border-left:4px solid #62dd4a;padding:12px 14px;border-radius:6px;white-space:pre-wrap">${esc(fb.message)}</div>
<p style="margin:16px 0"><a href="${SITE}" style="background:#62dd4a;color:#0b1c11;padding:10px 18px;border-radius:999px;text-decoration:none;font-weight:bold">Ouvrir le CRM</a></p></div>`;
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST', headers: { Authorization: 'Bearer ' + key, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: 'CRM C2E <onboarding@resend.dev>', to: emails, subject: `Nouveau retour (${kind}) de ${author?.full_name ?? 'l\'équipe'}`, html }),
  });
  if (!r.ok) return reply({ sent: false, reason: 'refus_fournisseur', status: r.status });
  await admin.from('feedback').update({ notified_at: new Date().toISOString() }).eq('id', id);
  return reply({ sent: true });
});
