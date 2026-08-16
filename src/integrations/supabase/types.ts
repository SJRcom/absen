export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      event_participants: {
        Row: {
          created_at: string
          event_id: string
          id: string
          participant_id: string
          position: Database["public"]["Enums"]["event_position"]
        }
        Insert: {
          created_at?: string
          event_id: string
          id?: string
          participant_id: string
          position: Database["public"]["Enums"]["event_position"]
        }
        Update: {
          created_at?: string
          event_id?: string
          id?: string
          participant_id?: string
          position?: Database["public"]["Enums"]["event_position"]
        }
        Relationships: [
          {
            foreignKeyName: "event_participants_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "event_participants_participant_id_fkey"
            columns: ["participant_id"]
            isOneToOne: false
            referencedRelation: "participants"
            referencedColumns: ["id"]
          },
        ]
      }
      events: {
        Row: {
          created_at: string
          event_date: string
          field_id: string
          gk_price: number
          gk_slots: number
          id: string
          name: string
          note: string | null
          player_price: number
          player_slots: number
          reserve_price: number
          reserve_slots: number
          status: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          event_date?: string
          field_id: string
          gk_price?: number
          gk_slots?: number
          id?: string
          name: string
          note?: string | null
          player_price?: number
          player_slots?: number
          reserve_price?: number
          reserve_slots?: number
          status?: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          event_date?: string
          field_id?: string
          gk_price?: number
          gk_slots?: number
          id?: string
          name?: string
          note?: string | null
          player_price?: number
          player_slots?: number
          reserve_price?: number
          reserve_slots?: number
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "events_field_id_fkey"
            columns: ["field_id"]
            isOneToOne: false
            referencedRelation: "fields"
            referencedColumns: ["id"]
          },
        ]
      }
      fields: {
        Row: {
          active: boolean
          base_price: number
          created_at: string
          description: string | null
          id: string
          name: string
          updated_at: string
        }
        Insert: {
          active?: boolean
          base_price: number
          created_at?: string
          description?: string | null
          id?: string
          name: string
          updated_at?: string
        }
        Update: {
          active?: boolean
          base_price?: number
          created_at?: string
          description?: string | null
          id?: string
          name?: string
          updated_at?: string
        }
        Relationships: []
      }
      participants: {
        Row: {
          balance: number
          card_uid: string
          created_at: string
          id: string
          member_no: string | null
          name: string
          note: string | null
          phone: string | null
          pin_hash: string | null
          rate_multiplier: number
          updated_at: string
        }
        Insert: {
          balance?: number
          card_uid: string
          created_at?: string
          id?: string
          member_no?: string | null
          name: string
          note?: string | null
          phone?: string | null
          pin_hash?: string | null
          rate_multiplier?: number
          updated_at?: string
        }
        Update: {
          balance?: number
          card_uid?: string
          created_at?: string
          id?: string
          member_no?: string | null
          name?: string
          note?: string | null
          phone?: string | null
          pin_hash?: string | null
          rate_multiplier?: number
          updated_at?: string
        }
        Relationships: []
      }
      products: {
        Row: {
          active: boolean
          category: string
          created_at: string
          description: string | null
          id: string
          name: string
          price: number
          updated_at: string
        }
        Insert: {
          active?: boolean
          category?: string
          created_at?: string
          description?: string | null
          id?: string
          name: string
          price?: number
          updated_at?: string
        }
        Update: {
          active?: boolean
          category?: string
          created_at?: string
          description?: string | null
          id?: string
          name?: string
          price?: number
          updated_at?: string
        }
        Relationships: []
      }
      profiles: {
        Row: {
          created_at: string
          full_name: string | null
          id: string
        }
        Insert: {
          created_at?: string
          full_name?: string | null
          id: string
        }
        Update: {
          created_at?: string
          full_name?: string | null
          id?: string
        }
        Relationships: []
      }
      transactions: {
        Row: {
          amount: number
          balance_after: number
          created_at: string
          event_id: string | null
          field_id: string | null
          id: string
          note: string | null
          operator_id: string | null
          participant_id: string
          position: Database["public"]["Enums"]["event_position"] | null
          product_id: string | null
          qty: number | null
          tx_type: Database["public"]["Enums"]["tx_type"]
        }
        Insert: {
          amount: number
          balance_after: number
          created_at?: string
          event_id?: string | null
          field_id?: string | null
          id?: string
          note?: string | null
          operator_id?: string | null
          participant_id: string
          position?: Database["public"]["Enums"]["event_position"] | null
          product_id?: string | null
          qty?: number | null
          tx_type: Database["public"]["Enums"]["tx_type"]
        }
        Update: {
          amount?: number
          balance_after?: number
          created_at?: string
          event_id?: string | null
          field_id?: string | null
          id?: string
          note?: string | null
          operator_id?: string | null
          participant_id?: string
          position?: Database["public"]["Enums"]["event_position"] | null
          product_id?: string | null
          qty?: number | null
          tx_type?: Database["public"]["Enums"]["tx_type"]
        }
        Relationships: [
          {
            foreignKeyName: "transactions_event_id_fkey"
            columns: ["event_id"]
            isOneToOne: false
            referencedRelation: "events"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "transactions_field_id_fkey"
            columns: ["field_id"]
            isOneToOne: false
            referencedRelation: "fields"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "transactions_participant_id_fkey"
            columns: ["participant_id"]
            isOneToOne: false
            referencedRelation: "participants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "transactions_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
        ]
      }
      user_roles: {
        Row: {
          id: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Insert: {
          id?: string
          role: Database["public"]["Enums"]["app_role"]
          user_id: string
        }
        Update: {
          id?: string
          role?: Database["public"]["Enums"]["app_role"]
          user_id?: string
        }
        Relationships: []
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      buy_product: {
        Args: { _card_uid: string; _product_id: string; _qty?: number }
        Returns: Json
      }
      buy_product_member: {
        Args: { _member_no: string; _product_id: string; _qty?: number }
        Returns: Json
      }
      has_role: {
        Args: {
          _role: Database["public"]["Enums"]["app_role"]
          _user_id: string
        }
        Returns: boolean
      }
      is_staff: { Args: { _user_id: string }; Returns: boolean }
      is_super_admin: { Args: { _user_id: string }; Returns: boolean }
      list_app_users: {
        Args: never
        Returns: {
          created_at: string
          email: string
          full_name: string
          roles: string[]
          user_id: string
        }[]
      }
      member_lookup: {
        Args: { _card_uid?: string; _member_no?: string; _pin?: string }
        Returns: Json
      }
      my_access: { Args: never; Returns: Json }
      scan_and_pay: {
        Args: { _card_uid: string; _field_id: string }
        Returns: Json
      }
      scan_event_and_pay: {
        Args: { _card_uid: string; _event_id: string }
        Returns: Json
      }
      scan_member_and_pay: {
        Args: { _field_id: string; _member_no: string }
        Returns: Json
      }
      scan_member_event_and_pay: {
        Args: { _event_id: string; _member_no: string }
        Returns: Json
      }
      set_member_pin: {
        Args: { _participant_id: string; _pin: string }
        Returns: Json
      }
      set_user_staff: {
        Args: { _make_staff: boolean; _user_id: string }
        Returns: Json
      }
      topup_balance: {
        Args: { _amount: number; _note?: string; _participant_id: string }
        Returns: Json
      }
    }
    Enums: {
      app_role: "admin" | "operator" | "super_admin" | "member"
      event_position: "gk" | "player" | "reserve"
      tx_type: "attendance" | "topup" | "adjustment" | "purchase"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      app_role: ["admin", "operator", "super_admin", "member"],
      event_position: ["gk", "player", "reserve"],
      tx_type: ["attendance", "topup", "adjustment", "purchase"],
    },
  },
} as const
