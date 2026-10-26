-- Alerte e-mail à la réception d'un retour : on note quand l'e-mail est parti pour ne jamais l'envoyer deux fois.
alter table public.feedback add column notified_at timestamptz;
