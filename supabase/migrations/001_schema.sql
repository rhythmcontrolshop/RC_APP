-- ═══════════════════════════════════════════════════════════════════════════
-- RHYTHM CONTROL — SCHEMA INICIAL (001)
-- Una sola migración limpia. Ejecutar en Supabase SQL Editor.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── EXTENSIONES ─────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─── TIPOS ENUM ──────────────────────────────────────────────────────────────
CREATE TYPE discogs_status_enum AS ENUM ('for_sale', 'draft', 'expired', 'sold');
CREATE TYPE youtube_status_enum AS ENUM ('none', 'pending_review', 'approved', 'rejected');
CREATE TYPE order_status_enum   AS ENUM ('pending', 'payment_confirmed', 'processing', 'shipped', 'delivered', 'cancelled', 'refunded');
CREATE TYPE payment_status_enum AS ENUM ('pending', 'paid', 'failed', 'refunded');
CREATE TYPE delivery_type_enum  AS ENUM ('shipping', 'pickup');
CREATE TYPE event_type_enum     AS ENUM ('event', 'mix');
CREATE TYPE user_role_enum      AS ENUM ('customer', 'admin');

-- ─── FUNCIÓN: updated_at automático ─────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: profiles
-- Extiende auth.users. Se crea automáticamente en el trigger de registro.
-- is_admin() se define DESPUÉS de profiles para que pueda referenciarla.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE profiles (
  id               uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email            text NOT NULL,
  full_name        text,
  phone            text,
  role             user_role_enum NOT NULL DEFAULT 'customer',
  default_address  jsonb,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Trigger: crear perfil automáticamente al registrarse
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, email)
  VALUES (NEW.id, NEW.email)
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ─── FUNCIÓN: is_admin (security definer) ────────────────────────────────────
-- Definida AQUÍ, después de profiles, para que la referencia sea válida.
CREATE OR REPLACE FUNCTION is_admin()
RETURNS boolean LANGUAGE sql SECURITY DEFINER STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
$$;

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: releases
-- Una fila = un listing de Discogs = una unidad física.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE releases (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  discogs_listing_id   bigint UNIQUE NOT NULL,
  discogs_release_id   bigint NOT NULL,
  discogs_status       discogs_status_enum NOT NULL DEFAULT 'for_sale',
  title                text NOT NULL,
  artist               text NOT NULL,
  label                text NOT NULL DEFAULT '',
  catno                text NOT NULL DEFAULT '',
  year                 integer,
  format               text NOT NULL DEFAULT '',
  genres               text[] NOT NULL DEFAULT '{}',
  styles               text[] NOT NULL DEFAULT '{}',
  condition            text NOT NULL,
  sleeve_condition     text NOT NULL DEFAULT '',
  notes                text,
  ships_from           text NOT NULL DEFAULT 'Spain',
  discogs_price        integer NOT NULL,   -- céntimos
  web_price            integer NOT NULL,   -- céntimos, independiente de Discogs
  extra_stock          integer NOT NULL DEFAULT 0,
  images               text[] NOT NULL DEFAULT '{}',
  thumb                text,
  youtube_url          text,
  youtube_status       youtube_status_enum NOT NULL DEFAULT 'none',
  is_new               boolean NOT NULL DEFAULT false,
  is_staff_pick        boolean NOT NULL DEFAULT false,
  is_featured          boolean NOT NULL DEFAULT false,
  synced_at            timestamptz NOT NULL DEFAULT now(),
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT releases_web_price_positive CHECK (web_price >= 0),
  CONSTRAINT releases_extra_stock_positive CHECK (extra_stock >= 0)
);

CREATE TRIGGER trg_releases_updated_at
  BEFORE UPDATE ON releases
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_releases_discogs_listing ON releases (discogs_listing_id);
CREATE INDEX idx_releases_discogs_release ON releases (discogs_release_id);
CREATE INDEX idx_releases_status ON releases (discogs_status);
CREATE INDEX idx_releases_genres ON releases USING GIN (genres);
CREATE INDEX idx_releases_styles ON releases USING GIN (styles);
CREATE INDEX idx_releases_youtube_status ON releases (youtube_status);
CREATE INDEX idx_releases_is_new ON releases (is_new) WHERE is_new = true;
CREATE INDEX idx_releases_is_featured ON releases (is_featured) WHERE is_featured = true;
CREATE INDEX idx_releases_web_price ON releases (web_price);
CREATE INDEX idx_releases_synced_at ON releases (synced_at DESC);

-- Vista: stock disponible. security_invoker=true para que respete RLS del caller.
CREATE OR REPLACE VIEW available_releases
  WITH (security_invoker = true)
AS
SELECT *,
  (CASE WHEN discogs_status = 'for_sale' THEN 1 ELSE 0 END + extra_stock) AS total_stock
FROM releases
WHERE (discogs_status = 'for_sale' OR extra_stock > 0);

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: favorites
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE favorites (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  release_id uuid NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, release_id)
);

CREATE INDEX idx_favorites_user ON favorites (user_id);
CREATE INDEX idx_favorites_release ON favorites (release_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: carts
-- Soporta carrito de invitado (user_id NULL) y usuario autenticado.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE carts (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    uuid REFERENCES profiles(id) ON DELETE CASCADE,
  session_id text,   -- para carritos de invitado
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cart_owner CHECK (
    (user_id IS NOT NULL AND session_id IS NULL) OR
    (user_id IS NULL AND session_id IS NOT NULL)
  )
);

CREATE TRIGGER trg_carts_updated_at
  BEFORE UPDATE ON carts
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_carts_user ON carts (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX idx_carts_session ON carts (session_id) WHERE session_id IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: cart_items
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE cart_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  cart_id              uuid NOT NULL REFERENCES carts(id) ON DELETE CASCADE,
  release_id           uuid NOT NULL REFERENCES releases(id) ON DELETE CASCADE,
  discogs_listing_id   bigint NOT NULL,
  web_price_snapshot   integer NOT NULL,  -- precio en el momento de añadir, céntimos
  quantity             integer NOT NULL DEFAULT 1,
  added_at             timestamptz NOT NULL DEFAULT now(),
  UNIQUE (cart_id, release_id),
  CONSTRAINT cart_items_quantity CHECK (quantity >= 1)
);

CREATE INDEX idx_cart_items_cart ON cart_items (cart_id);
CREATE INDEX idx_cart_items_release ON cart_items (release_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: orders
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE orders (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid REFERENCES profiles(id) ON DELETE SET NULL,
  guest_email          text,
  guest_name           text,
  subtotal             integer NOT NULL,          -- céntimos
  shipping_cost        integer NOT NULL DEFAULT 0,
  total                integer NOT NULL,          -- céntimos
  delivery_type        delivery_type_enum NOT NULL,
  shipping_address     jsonb,
  status               order_status_enum NOT NULL DEFAULT 'pending',
  payment_status       payment_status_enum NOT NULL DEFAULT 'pending',
  redsys_order_id      text UNIQUE,
  redsys_response      jsonb,
  packlink_shipment_id text,
  tracking_number      text,
  tracking_url         text,
  notes                text,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT order_owner CHECK (
    (user_id IS NOT NULL) OR (guest_email IS NOT NULL)
  ),
  CONSTRAINT order_shipping_address CHECK (
    delivery_type = 'pickup' OR shipping_address IS NOT NULL
  )
);

CREATE TRIGGER trg_orders_updated_at
  BEFORE UPDATE ON orders
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_orders_user ON orders (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX idx_orders_guest_email ON orders (guest_email) WHERE guest_email IS NOT NULL;
CREATE INDEX idx_orders_status ON orders (status);
CREATE INDEX idx_orders_payment_status ON orders (payment_status);
CREATE INDEX idx_orders_redsys ON orders (redsys_order_id) WHERE redsys_order_id IS NOT NULL;
CREATE INDEX idx_orders_created_at ON orders (created_at DESC);

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: order_items
-- Snapshot del precio y datos en el momento de la compra.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE order_items (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id             uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  release_id           uuid REFERENCES releases(id) ON DELETE SET NULL,
  discogs_listing_id   bigint NOT NULL,
  title                text NOT NULL,
  artist               text NOT NULL,
  format               text NOT NULL DEFAULT '',
  condition            text NOT NULL DEFAULT '',
  price                integer NOT NULL,  -- céntimos al momento de compra
  quantity             integer NOT NULL DEFAULT 1,
  discogs_marked_sold  boolean NOT NULL DEFAULT false
);

CREATE INDEX idx_order_items_order ON order_items (order_id);
CREATE INDEX idx_order_items_release ON order_items (release_id) WHERE release_id IS NOT NULL;
CREATE INDEX idx_order_items_discogs ON order_items (discogs_listing_id);

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: events
-- Eventos físicos y mixes para la sección Escena.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE events (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type         event_type_enum NOT NULL,
  title        text NOT NULL,
  description  text,
  date         date,              -- NULL permitido para mixes
  flyer_url    text,              -- Supabase Storage URL
  mix_url      text,              -- Mixcloud/Soundcloud URL
  mix_embed    text,              -- HTML embed snippet
  is_published boolean NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_events_updated_at
  BEFORE UPDATE ON events
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_events_type ON events (type);
CREATE INDEX idx_events_published ON events (is_published) WHERE is_published = true;
CREATE INDEX idx_events_date ON events (date DESC) WHERE date IS NOT NULL;

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: shipping_zones
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE shipping_zones (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  countries   text[] NOT NULL DEFAULT '{}',  -- códigos ISO 3166-1 alpha-2
  base_rate   integer NOT NULL,              -- céntimos
  free_above  integer,                       -- céntimos, NULL = nunca gratis
  carrier     text NOT NULL DEFAULT '',
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_shipping_zones_updated_at
  BEFORE UPDATE ON shipping_zones
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE INDEX idx_shipping_zones_active ON shipping_zones (is_active) WHERE is_active = true;
CREATE INDEX idx_shipping_zones_countries ON shipping_zones USING GIN (countries);

-- Zona por defecto: España
INSERT INTO shipping_zones (name, countries, base_rate, free_above, carrier)
VALUES
  ('España', ARRAY['ES'], 500, 7000, 'Correos'),
  ('Europa', ARRAY['DE','FR','IT','PT','NL','BE','AT','PL','SE','DK','FI','NO','CH','IE'], 1200, NULL, 'Correos'),
  ('Resto del mundo', ARRAY[]::text[], 2000, NULL, 'Correos');

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: sync_logs
-- Registro de sincronizaciones con Discogs.
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE sync_logs (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  started_at      timestamptz NOT NULL DEFAULT now(),
  finished_at     timestamptz,
  status          text NOT NULL DEFAULT 'running'
                  CHECK (status IN ('running', 'success', 'error')),
  listings_found  integer,
  listings_new    integer,
  listings_updated integer,
  listings_sold   integer,
  error_message   text,
  triggered_by    text NOT NULL DEFAULT 'cron'
                  CHECK (triggered_by IN ('cron', 'admin', 'manual'))
);

CREATE INDEX idx_sync_logs_started ON sync_logs (started_at DESC);

-- ═══════════════════════════════════════════════════════════════════════════
-- TABLA: site_settings
-- Configuración general de la tienda (clave-valor).
-- ═══════════════════════════════════════════════════════════════════════════
CREATE TABLE site_settings (
  key        text PRIMARY KEY,
  value      text NOT NULL DEFAULT '',
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_site_settings_updated_at
  BEFORE UPDATE ON site_settings
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

INSERT INTO site_settings (key, value) VALUES
  ('store_name', 'Rhythm Control'),
  ('store_address', 'Carrer de Guàrdia, Barcelona'),
  ('store_email', 'info@rhythmcontrol.shop'),
  ('store_phone', ''),
  ('store_hours', 'Mar–Sáb 12:00–20:00'),
  ('instagram_url', 'https://instagram.com/rhythmcontrolshop'),
  ('tiktok_url', ''),
  ('discogs_username', 'rhythmcontrol');

-- ═══════════════════════════════════════════════════════════════════════════
-- RLS — ROW LEVEL SECURITY
-- Habilitado en todas las tablas, sin excepción.
-- ═══════════════════════════════════════════════════════════════════════════

ALTER TABLE profiles       ENABLE ROW LEVEL SECURITY;
ALTER TABLE releases       ENABLE ROW LEVEL SECURITY;
ALTER TABLE favorites      ENABLE ROW LEVEL SECURITY;
ALTER TABLE carts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE cart_items     ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders         ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items    ENABLE ROW LEVEL SECURITY;
ALTER TABLE events         ENABLE ROW LEVEL SECURITY;
ALTER TABLE shipping_zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_logs      ENABLE ROW LEVEL SECURITY;
ALTER TABLE site_settings  ENABLE ROW LEVEL SECURITY;

-- ── profiles ──────────────────────────────────────────────────────────────
CREATE POLICY "profiles: usuario lee/edita el suyo" ON profiles
  FOR ALL USING (auth.uid() = id);

CREATE POLICY "profiles: admin lee todos" ON profiles
  FOR SELECT USING (is_admin());

-- ── releases ──────────────────────────────────────────────────────────────
CREATE POLICY "releases: lectura pública" ON releases
  FOR SELECT USING (true);

CREATE POLICY "releases: admin escribe" ON releases
  FOR ALL USING (is_admin());

-- ── favorites ─────────────────────────────────────────────────────────────
CREATE POLICY "favorites: usuario gestiona los suyos" ON favorites
  FOR ALL USING (auth.uid() = user_id);

-- ── carts ─────────────────────────────────────────────────────────────────
CREATE POLICY "carts: usuario autenticado gestiona el suyo" ON carts
  FOR ALL USING (auth.uid() = user_id);

-- Nota: los carritos de invitado se gestionan via service_role en la API.

-- ── cart_items ────────────────────────────────────────────────────────────
CREATE POLICY "cart_items: acceso via carrito del usuario" ON cart_items
  FOR ALL USING (
    EXISTS (
      SELECT 1 FROM carts
      WHERE carts.id = cart_items.cart_id
        AND carts.user_id = auth.uid()
    )
  );

-- ── orders ────────────────────────────────────────────────────────────────
CREATE POLICY "orders: usuario ve los suyos" ON orders
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY "orders: admin gestiona todos" ON orders
  FOR ALL USING (is_admin());

-- ── order_items ───────────────────────────────────────────────────────────
CREATE POLICY "order_items: usuario ve los suyos via pedido" ON order_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM orders
      WHERE orders.id = order_items.order_id
        AND orders.user_id = auth.uid()
    )
  );

CREATE POLICY "order_items: admin gestiona todos" ON order_items
  FOR ALL USING (is_admin());

-- ── events ────────────────────────────────────────────────────────────────
CREATE POLICY "events: lectura pública de publicados" ON events
  FOR SELECT USING (is_published = true);

CREATE POLICY "events: admin gestiona todos" ON events
  FOR ALL USING (is_admin());

-- ── shipping_zones ────────────────────────────────────────────────────────
CREATE POLICY "shipping_zones: lectura pública de activas" ON shipping_zones
  FOR SELECT USING (is_active = true);

CREATE POLICY "shipping_zones: admin gestiona todas" ON shipping_zones
  FOR ALL USING (is_admin());

-- ── sync_logs ─────────────────────────────────────────────────────────────
CREATE POLICY "sync_logs: solo admin" ON sync_logs
  FOR ALL USING (is_admin());

-- ── site_settings ─────────────────────────────────────────────────────────
CREATE POLICY "site_settings: lectura pública" ON site_settings
  FOR SELECT USING (true);

CREATE POLICY "site_settings: admin escribe" ON site_settings
  FOR ALL USING (is_admin());

-- ═══════════════════════════════════════════════════════════════════════════
-- STORAGE BUCKETS
-- Ejecutar después de crear las tablas.
-- ═══════════════════════════════════════════════════════════════════════════

-- Bucket: event-flyers (público, sólo admin puede subir)
INSERT INTO storage.buckets (id, name, public)
VALUES ('event-flyers', 'event-flyers', true)
ON CONFLICT DO NOTHING;

CREATE POLICY "event-flyers: lectura pública" ON storage.objects
  FOR SELECT USING (bucket_id = 'event-flyers');

CREATE POLICY "event-flyers: admin sube" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'event-flyers' AND is_admin());

CREATE POLICY "event-flyers: admin borra" ON storage.objects
  FOR DELETE USING (bucket_id = 'event-flyers' AND is_admin());
