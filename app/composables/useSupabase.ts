import { createClient, type SupabaseClient } from '@supabase/supabase-js'

let client: SupabaseClient | null = null

export function useSupabase(): SupabaseClient {
  if (!client) {
    const { supabaseUrl, supabaseAnonKey } = useRuntimeConfig().public
    client = createClient(supabaseUrl, supabaseAnonKey, {
      auth: { persistSession: true, detectSessionInUrl: true, flowType: 'pkce' },
    })
  }
  return client
}

export interface Member { id: string, full_name: string, email: string, role: string, user_id: string | null }

/** Miembro del equipo que tiene la sesión abierta (null si no es del equipo). */
export const useMe = () => useState<Member | null>('me', () => null)
export const useTeam = () => useState<Member[]>('team', () => [])

export async function loadTeam() {
  const sb = useSupabase()
  const { data: { user } } = await sb.auth.getUser()
  const { data } = await sb.from('team_members').select('id, full_name, email, role, user_id').eq('active', true).order('full_name')
  useTeam().value = data ?? []
  useMe().value = (data ?? []).find(m => m.user_id === user?.id) ?? null
}
