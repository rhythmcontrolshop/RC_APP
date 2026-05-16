export type Locale = "es" | "ca" | "en";

export type DiscogsCondition =
  | "Mint (M)"
  | "Near Mint (NM or M-)"
  | "Very Good Plus (VG+)"
  | "Very Good (VG)"
  | "Good Plus (G+)"
  | "Good (G)"
  | "Fair (F)"
  | "Poor (P)";

export type DiscogsStatus = "for_sale" | "draft" | "expired" | "sold";

export type YoutubeStatus = "pending_review" | "approved" | "rejected" | "none";

export type DeliveryType = "shipping" | "pickup";

export type OrderStatus =
  | "pending"
  | "payment_confirmed"
  | "processing"
  | "shipped"
  | "delivered"
  | "cancelled"
  | "refunded";

export type PaymentStatus = "pending" | "paid" | "failed" | "refunded";

export type EventType = "event" | "mix";

// ── Discogs raw listing from API ──
export interface DiscogsListing {
  id: number;
  status: DiscogsStatus;
  price: {
    value: number;
    currency: string;
  };
  release: {
    id: number;
    description: string;
    title: string;
    artist: string;
    format: string;
    label: string;
    catno: string;
    year: number;
    resource_url: string;
    thumbnail: string;
  };
  condition: DiscogsCondition;
  sleeve_condition: DiscogsCondition;
  comments: string;
  ships_from: string;
  posted: string;
}

// ── Internal Release model (DB) ──
export interface Release {
  id: string; // uuid
  discogs_listing_id: number;
  discogs_release_id: number;
  discogs_status: DiscogsStatus;
  title: string;
  artist: string;
  label: string;
  catno: string;
  year: number | null;
  format: string;
  genres: string[];
  styles: string[];
  condition: DiscogsCondition;
  sleeve_condition: DiscogsCondition;
  notes: string | null;
  ships_from: string;
  discogs_price: number; // in cents
  web_price: number; // in cents, independent
  extra_stock: number;
  images: string[];
  thumb: string | null;
  youtube_url: string | null;
  youtube_status: YoutubeStatus;
  is_new: boolean;
  is_staff_pick: boolean;
  is_featured: boolean;
  synced_at: string;
  created_at: string;
  updated_at: string;
}

// ── Cart ──
export interface CartItem {
  release_id: string;
  discogs_listing_id: number;
  title: string;
  artist: string;
  web_price: number; // cents
  thumb: string | null;
  quantity: number; // always 1 for Discogs units
}

export interface Cart {
  id: string;
  user_id: string | null; // null = guest
  items: CartItem[];
  created_at: string;
  updated_at: string;
}

// ── User ──
export interface User {
  id: string; // Supabase auth uid
  email: string;
  full_name: string | null;
  phone: string | null;
  default_address: ShippingAddress | null;
  created_at: string;
}

export interface ShippingAddress {
  full_name: string;
  line1: string;
  line2: string | null;
  city: string;
  postal_code: string;
  province: string;
  country: string; // ISO 3166-1 alpha-2
  phone: string;
}

// ── Order ──
export interface Order {
  id: string;
  user_id: string | null;
  guest_email: string | null;
  items: OrderItem[];
  subtotal: number; // cents
  shipping_cost: number; // cents
  total: number; // cents
  delivery_type: DeliveryType;
  shipping_address: ShippingAddress | null;
  status: OrderStatus;
  payment_status: PaymentStatus;
  redsys_order_id: string | null;
  packlink_shipment_id: string | null;
  tracking_number: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
}

export interface OrderItem {
  release_id: string;
  discogs_listing_id: number;
  title: string;
  artist: string;
  price: number; // cents at time of purchase
  quantity: number;
}

// ── Escena — Events ──
export interface Event {
  id: string;
  type: EventType;
  title: string;
  description: string | null;
  date: string | null; // ISO date, null for mixes
  flyer_url: string | null; // Storage URL
  mix_url: string | null; // Mixcloud/Soundcloud URL
  mix_embed: string | null; // embed HTML
  is_published: boolean;
  created_at: string;
}

// ── Escena — Mixes (alias for clarity) ──
export type Mix = Event & { type: "mix" };

// ── Shipping ──
export interface ShippingZone {
  id: string;
  name: string;
  countries: string[]; // ISO 3166-1 alpha-2
  base_rate: number; // cents
  free_above: number | null; // cents, null = never free
  carrier: string;
  is_active: boolean;
}
