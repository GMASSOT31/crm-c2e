import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.118.0';

// Création d'un compte par l'administrateur : génère un lien d'invitation à usage unique
// (la personne choisit elle-même son mot de passe). Aucun mot de passe n'est créé ici.
const SITE = 'https://gmassot31.github.io/crm-c2e/';
const ROLES = ['admin', 'secretariat', 'commercial'];
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const svc = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const authHeader = req.headers.get('Authorization') ?? '';

  const asUser = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: u } = await asUser.auth.getUser();
  if (!u?.user) return reply({ error: 'Non connecté.' }, 401);
  const { data: me } = await asUser.from('profiles').select('role,active').eq('id', u.user.id).maybeSingle();
  if (!me || !me.active || me.role !== 'admin') return reply({ error: 'Réservé à l\'administrateur.' }, 403);

  let body: { email?: string; name?: string; role?: string; temp?: boolean; reset_user?: string };
  try { body = await req.json(); } catch { return reply({ error: 'Requête illisible.' }, 400); }
  const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
  const newPassword = () => Array.from(crypto.getRandomValues(new Uint8Array(14)), (b) => alphabet[b % alphabet.length]).join('');
  if (body.reset_user) {
    // Réinitialisation : nouveau mot de passe provisoire (affiché une seule fois), changement obligatoire à la prochaine connexion.
    const adm = createClient(url, svc);
    const { data: target } = await adm.from('profiles').select('id,full_name').eq('id', body.reset_user).maybeSingle();
    if (!target) return reply({ error: 'Compte introuvable.' }, 404);
    const pw = newPassword();
    const { error: ue } = await adm.auth.admin.updateUserById(target.id, { password: pw, user_metadata: { must_change_password: true } });
    if (ue) return reply({ error: 'Réinitialisation impossible : ' + ue.message }, 400);
    await adm.from('audit_log').insert({ actor: u.user.id, action: 'reset_password', entity: 'profiles', entity_id: target.id });
    return reply({ password: pw, name: target.full_name });
  }
  const email = String(body.email ?? '').trim().toLowerCase();
  const name = String(body.name ?? '').trim();
  const role = String(body.role ?? '');
  if (!/^[^\s@,]+@[^\s@,]+\.[a-z]{2,}$/.test(email)) return reply({ error: 'Adresse email invalide.' }, 400);
  if (!name) return reply({ error: 'Le nom est obligatoire.' }, 400);
  if (!ROLES.includes(role)) return reply({ error: 'Rôle inconnu.' }, 400);

  const admin = createClient(url, svc);
  let uid: string; let link: string | undefined; let password: string | undefined;
  if (body.temp) {
    // Mot de passe provisoire : généré ici, montré une seule fois à l'administrateur, changement obligatoire à la 1re connexion.
    password = newPassword();
    const { data, error } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { must_change_password: true },
    });
    if (error || !data?.user) {
      const m = error?.message ?? '';
      return reply({ error: /already|registered|exists/i.test(m) ? 'Un compte existe déjà avec cet email.' : 'Création impossible : ' + m }, 400);
    }
    uid = data.user.id;
  } else {
    const { data, error } = await admin.auth.admin.generateLink({ type: 'invite', email, options: { redirectTo: SITE } });
    if (error || !data?.user) {
      const m = error?.message ?? '';
      return reply({ error: /already|registered|exists/i.test(m) ? 'Un compte existe déjà avec cet email.' : 'Création impossible : ' + m }, 400);
    }
    uid = data.user.id;
    link = data.properties.action_link;
  }
  const { error: pe } = await admin.from('profiles').upsert({ id: uid, full_name: name, role, active: true });
  if (pe) return reply({ error: 'Compte créé mais profil non enregistré : ' + pe.message }, 500);
  await admin.from('audit_log').insert({ actor: u.user.id, action: 'invite_user', entity: 'profiles', entity_id: uid, details: { role, temp: !!body.temp } });
  return reply({ link, password, id: uid });
});
