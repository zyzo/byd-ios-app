// Trip and energy log kept in the BydServer Durable Object's SQLite.
//
// The container (server.py) only keeps a short ring of car snapshots; the Worker's cron pulls
// them here, derives trips, prices them and attaches the phones' departure/arrival events.
// Everything below is plain ESM with no Cloudflare imports so the maths can run under node:test.

export const DEFAULT_EV_RATE = 0.17; // kWh per km, until enough all-electric trips teach a real one
export const EVENT_WINDOW_MS = 15 * 60 * 1000;
export const CALIBRATION_READINGS = 3;
export const CALIBRATION_TOLERANCE = 0.1;
export const CHARGE_MIN_RISE = 5; // battery points gained while parked before it counts as a charge
export const DEFAULT_CHARGE_EFFICIENCY = 0.9; // share of the charger's kWh that reaches the battery
const ENERGY_INTERVAL_MS = 60 * 60 * 1000;
const EVENT_RETENTION_DAYS = 7;

const SCHEMA_VERSION = 4;

const MIGRATIONS = [
  // v1
  `
  CREATE TABLE IF NOT EXISTS snapshots (
    at TEXT PRIMARY KEY,
    received_at TEXT,
    odometer_km REAL NOT NULL,
    battery_percent REAL NOT NULL,
    fuel_percent REAL,
    range_electric_km REAL,
    range_fuel_km REAL,
    power_on INTEGER NOT NULL,
    charging INTEGER NOT NULL,
    source TEXT
  );
  CREATE TABLE IF NOT EXISTS trips (
    id TEXT PRIMARY KEY,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    odo_start REAL NOT NULL,
    odo_end REAL NOT NULL,
    soc_start REAL,
    soc_end REAL,
    fuel_start REAL,
    fuel_end REAL,
    kwh REAL,
    litres REAL,
    ev_km REAL,
    petrol_km REAL,
    price_kwh REAL,
    price_litre REAL,
    petrol_cycle TEXT,
    phone_id TEXT,
    start_lat REAL,
    start_lon REAL,
    end_lat REAL,
    end_lon REAL,
    flags TEXT NOT NULL DEFAULT '[]',
    source TEXT NOT NULL DEFAULT 'car',
    deleted_at TEXT,
    created_at TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS trips_end_at ON trips(end_at);
  CREATE TABLE IF NOT EXISTS phone_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    phone_id TEXT NOT NULL,
    kind TEXT NOT NULL,
    at TEXT NOT NULL,
    lat REAL,
    lon REAL,
    trip_id TEXT,
    UNIQUE(phone_id, kind, at)
  );
  CREATE TABLE IF NOT EXISTS phones (
    id TEXT PRIMARY KEY,
    name TEXT,
    last_seen TEXT
  );
  CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
  );
  CREATE TABLE IF NOT EXISTS leases (
    kind TEXT PRIMARY KEY,
    phone_id TEXT NOT NULL,
    until TEXT NOT NULL
  );
  `,
  // v2: the car's own start and end, kept apart from the phone-adjusted ones so events can be
  // re-matched at any time, and where a gap folded into the trip began.
  `
  ALTER TABLE trips ADD COLUMN car_start_at TEXT;
  ALTER TABLE trips ADD COLUMN car_end_at TEXT;
  ALTER TABLE trips ADD COLUMN gap_start_at TEXT;
  UPDATE trips SET car_start_at = start_at, car_end_at = end_at;
  `,
  // v3: what a refuel or a charge on the way really came to, as the person corrected it.
  `
  ALTER TABLE trips ADD COLUMN refills TEXT;
  `,
  // v4: charges while the car stood between two trips. kwh is what the charger delivered,
  // estimated from the battery's rise; edit holds what the person says it really came to.
  `
  CREATE TABLE IF NOT EXISTS charges (
    id TEXT PRIMARY KEY,
    parked_at TEXT NOT NULL,
    start_at TEXT NOT NULL,
    end_at TEXT NOT NULL,
    odometer_km REAL NOT NULL,
    soc_start REAL NOT NULL,
    soc_end REAL NOT NULL,
    charging_seen INTEGER NOT NULL,
    kwh REAL,
    price_kwh REAL,
    edit TEXT,
    deleted_at TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS charges_end_at ON charges(end_at);
  `,
];

function storedVersion(sql) {
  const table = sql.exec(`SELECT 1 AS x FROM sqlite_master WHERE type = 'table' AND name = 'schema_version'`).toArray();
  return table.length ? (sql.exec(`SELECT version FROM schema_version`).toArray()[0]?.version ?? 0) : 0;
}

// Runs every migration past the stored version. Safe to call on every request.
export function migrate(sql) {
  sql.exec(`CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)`);
  const row = sql.exec(`SELECT version FROM schema_version`).toArray()[0];
  let version = row ? row.version : 0;
  if (!row) sql.exec(`INSERT INTO schema_version (version) VALUES (0)`);
  while (version < SCHEMA_VERSION) {
    for (const statement of MIGRATIONS[version].split(";")) {
      if (statement.trim()) sql.exec(statement);
    }
    version += 1;
    sql.exec(`UPDATE schema_version SET version = ?`, version);
  }
  return version;
}

const iso = (value) => new Date(value).toISOString();
const ms = (value) => new Date(value).getTime();
const round = (value, digits = 2) => (value == null ? null : Math.round(value * 10 ** digits) / 10 ** digits);
const median = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};
const isNumber = (value) => typeof value === "number" && Number.isFinite(value);

// Snapshot fields as the container serves them, normalised.
export function normaliseSnapshot(raw) {
  return {
    at: iso(raw.at),
    receivedAt: raw.receivedAt ? iso(raw.receivedAt) : null,
    odometerKm: Number(raw.odometerKm),
    batteryPercent: Number(raw.batteryPercent),
    fuelPercent: isNumber(raw.fuelPercent) ? raw.fuelPercent : null,
    rangeElectricKm: isNumber(raw.rangeElectricKm) ? raw.rangeElectricKm : null,
    rangeFuelKm: isNumber(raw.rangeFuelKm) ? raw.rangeFuelKm : null,
    powerOn: Boolean(raw.powerOn),
    charging: Boolean(raw.charging),
    source: raw.source ?? null,
  };
}

function openFrom(snapshot) {
  return {
    startAt: snapshot.at,
    gapStartAt: null,
    odoStart: snapshot.odometerKm,
    socStart: snapshot.batteryPercent,
    fuelStart: snapshot.fuelPercent,
    chargedSeen: false,
    lastSnapshot: snapshot,
  };
}

// A power-on report that arrives with more kilometres than the last power-off one: the car
// reported late and the drive began somewhere in between. The trip takes the odometer, battery
// and fuel from that power-off report and remembers where the gap began, so a phone departure
// inside the gap can give it its real start.
function openAfterGap(prev, snapshot) {
  return {
    ...openFrom(snapshot),
    gapStartAt: prev.at,
    odoStart: prev.odometerKm,
    socStart: prev.batteryPercent,
    fuelStart: prev.fuelPercent,
  };
}

function closeTrip(open, snapshot, source) {
  return {
    id: crypto.randomUUID(),
    startAt: open.startAt,
    endAt: snapshot.at,
    gapStartAt: open.gapStartAt ?? null,
    odoStart: open.odoStart,
    odoEnd: snapshot.odometerKm,
    socStart: open.socStart,
    socEnd: snapshot.batteryPercent,
    fuelStart: open.fuelStart,
    fuelEnd: snapshot.fuelPercent,
    chargedSeen: open.chargedSeen || snapshot.charging,
    source,
  };
}

// While the car stands between two trips: where the battery was when it stopped, and when the
// car's charging flag came on and went off again, if it did.
function parkFrom(at, socStart) {
  return { startAt: at, socStart, chargeStartAt: null, chargeEndAt: null, chargingSeen: false };
}

function noteParked(parked, snapshot) {
  if (snapshot.charging) {
    parked.chargeStartAt ??= snapshot.at;
    parked.chargeEndAt = null;
    parked.chargingSeen = true;
  } else if (parked.chargingSeen && !parked.chargeEndAt) {
    parked.chargeEndAt = snapshot.at;
  }
}

// The stop before `trip` was a charge if the battery stood at least CHARGE_MIN_RISE points
// higher when the trip began than when the car stopped. The charging flag only dates it.
function chargeBefore(parked, trip) {
  if (!parked || !isNumber(parked.socStart) || !isNumber(trip.socStart)) return null;
  if (trip.socStart - parked.socStart < CHARGE_MIN_RISE) return null;
  return {
    id: crypto.randomUUID(),
    parkedAt: parked.startAt,
    startAt: parked.chargeStartAt ?? parked.startAt,
    endAt: parked.chargeEndAt ?? trip.startAt,
    odometerKm: trip.odoStart,
    socStart: parked.socStart,
    socEnd: trip.socStart,
    chargingSeen: parked.chargingSeen,
  };
}

// Walks snapshots (ascending by `at`) and turns power-on → power-off pairs into trips.
// `openTrip` is the trip still in progress from the previous run (or null); `prev` is the last
// snapshot seen before this batch. Kilometres driven before a late power-on report belong to
// the trip it opens; an odometer jump between two power-off reports (a drive the pushes missed
// entirely) becomes a `coarse` trip. A battery that rose while the car stood between two trips
// becomes a charge. Returns the closed trips, the charges and the new cursor so the caller can
// resume from exactly here next time.
export function deriveTrips(snapshots, openTrip = null, prev = null, parkedState = null) {
  const trips = [];
  const charges = [];
  let open = openTrip;
  let parked = parkedState;
  const emit = (trip) => {
    trips.push(trip);
    const charge = chargeBefore(parked, trip);
    if (charge) charges.push(charge);
    parked = parkFrom(trip.endAt, trip.socEnd);
  };
  for (const raw of snapshots) {
    const snapshot = normaliseSnapshot(raw);
    if (open) {
      if (snapshot.charging) open.chargedSeen = true;
      if (snapshot.powerOn) {
        open.lastSnapshot = snapshot;
      } else {
        if (snapshot.odometerKm - open.odoStart >= 1) emit(closeTrip(open, snapshot, "car"));
        open = null;
      }
    } else if (snapshot.powerOn) {
      const late = prev && !prev.powerOn && snapshot.odometerKm - prev.odometerKm >= 1;
      open = late ? openAfterGap(prev, snapshot) : openFrom(snapshot);
    } else if (prev && snapshot.odometerKm - prev.odometerKm >= 1) {
      emit(closeTrip(openFrom(prev), snapshot, "coarse"));
    } else {
      parked ??= parkFrom(snapshot.at, snapshot.batteryPercent);
    }
    if (!snapshot.powerOn && !open && parked) noteParked(parked, snapshot);
    prev = snapshot;
  }
  return { trips, charges, openTrip: open, prev, parked };
}

// Median kWh/km of all-electric trips of 5 km or more; the seed until there are any.
export function learnEvRate(trips) {
  const rates = trips
    .filter((t) => t.km >= 5 && t.litres === 0 && t.kwh > 0 && !t.flags?.includes("chargedDuringTrip"))
    .map((t) => t.kwh / t.km);
  return rates.length ? median(rates) : DEFAULT_EV_RATE;
}

// Fills in distance, energy, electric share, flags and (when both prices are known) cost.
export function computeTrip(trip, settings = {}, prices = null) {
  const batteryKwh = settings.batteryKwh ?? 0;
  const tankLitres = settings.tankLitres ?? 0;
  const evRate = settings.evRate ?? DEFAULT_EV_RATE;
  const km = Math.max(0, trip.odoEnd - trip.odoStart);
  const socDelta = isNumber(trip.socStart) && isNumber(trip.socEnd) ? trip.socStart - trip.socEnd : null;
  const fuelDelta = isNumber(trip.fuelStart) && isNumber(trip.fuelEnd) ? trip.fuelStart - trip.fuelEnd : null;
  const kwh = socDelta == null ? 0 : round((Math.max(0, socDelta) / 100) * batteryKwh);
  const litres = fuelDelta == null ? 0 : round((Math.max(0, fuelDelta) / 100) * tankLitres);

  const flags = [];
  // Only the car's charging flag counts: on a hybrid the engine tops the battery up while
  // driving, so a higher SoC at arrival is normal.
  if (trip.chargedSeen) flags.push("chargedDuringTrip");
  if (fuelDelta != null && fuelDelta < 0) flags.push("refuelledDuringTrip");
  if (km > 0 && socDelta === 0 && (fuelDelta === 0 || fuelDelta == null)) flags.push("tooShortToMeasure");
  if (!trip.phoneId) flags.push("withoutPhone");

  // No petrol burnt means the whole distance was electric; otherwise the learnt rate splits it.
  let evKm = litres === 0 ? km : Math.min(km, evRate > 0 ? kwh / evRate : 0);
  if (kwh === 0 && litres > 0) evKm = 0;
  evKm = round(evKm, 1);
  const petrolKm = round(km - evKm, 1);
  const electricShare = km > 0 ? round(evKm / km, 3) : null;

  const priceKwh = isNumber(settings.priceKwh) ? settings.priceKwh : null;
  const priceLitre = isNumber(settings.petrolOverrideVndPerLitre)
    ? settings.petrolOverrideVndPerLitre
    : isNumber(prices?.petrol?.vndPerLitre)
      ? prices.petrol.vndPerLitre
      : null;
  const petrolCycle = isNumber(settings.petrolOverrideVndPerLitre) ? null : (prices?.petrol?.cycle ?? null);
  let cost = null;
  if (priceKwh != null && priceLitre != null && km > 0) {
    const total = Math.round(kwh * priceKwh + litres * priceLitre);
    cost = { total, perKm: Math.round(total / km), priceKwh, priceLitre, petrolCycle };
  }

  return {
    ...trip,
    km,
    kwh,
    litres,
    evKm,
    petrolKm,
    electricShare,
    cost,
    flags,
    priceKwh,
    priceLitre,
    petrolCycle,
  };
}

const carStart = (trip) => trip.carStartAt ?? trip.startAt;

// Picks one phone's departure for a trip: the earliest one in the window that the phone did
// not follow with an arrival before the car's own start, so a link that drops and comes back
// while walking past the parked car does not count.
function pickDeparture(events, free, from, to, startMs) {
  return free.find(
    (e) =>
      e.kind === "departure" &&
      ms(e.at) >= from &&
      ms(e.at) <= to &&
      !events.some((later) => later.kind === "arrival" && ms(later.at) > ms(e.at) && ms(later.at) < startMs),
  );
}

// And its arrival: the last one in the window before the phone's next departure after the car's
// end, so the link flapping while parking resolves to the moment the phone finally left.
function pickArrival(events, free, from, to, endMs) {
  const next = events.find((e) => e.kind === "departure" && ms(e.at) > endMs);
  const limit = next ? Math.min(to, ms(next.at)) : to;
  return free.filter((e) => e.kind === "arrival" && ms(e.at) >= from && ms(e.at) <= limit).at(-1);
}

// Matches the phones' departure/arrival events to trips, from the car's own times every time so
// it can be rerun as events come in. A departure within 15 minutes of the car's start (or
// inside the gap the trip folded in) sets the trip's phone and start; an arrival within 15
// minutes of the car's end sets its end. A coarse trip takes events from between its two
// reports. Events already attached to another trip than the ones given are left alone.
// Returns every trip with its phone fields recomputed, and which event went to which trip.
export function attachEvents(trips, events) {
  const attachments = [];
  const taken = new Set();
  const ids = new Set(trips.map((t) => t.id));
  const sorted = [...events].filter((e) => !e.tripId || ids.has(e.tripId)).sort((a, b) => ms(a.at) - ms(b.at));
  const phones = [...new Set(sorted.map((e) => e.phoneId))];
  const candidates = trips.filter((t) => !t.deletedAt).sort((a, b) => ms(carStart(a)) - ms(carStart(b)));
  const result = [];

  for (const trip of candidates) {
    const start = ms(carStart(trip));
    const end = ms(trip.carEndAt ?? trip.endAt);
    const coarse = trip.source === "coarse";
    const departFrom = coarse ? start : trip.gapStartAt ? ms(trip.gapStartAt) : start - EVENT_WINDOW_MS;
    const departTo = coarse ? end : start + EVENT_WINDOW_MS;
    const arriveFrom = Math.max(coarse ? start : end - EVENT_WINDOW_MS, start);
    const arriveTo = end + EVENT_WINDOW_MS;

    const matches = [];
    for (const phoneId of phones) {
      const own = sorted.filter((e) => e.phoneId === phoneId);
      const free = own.filter((e) => !taken.has(e));
      const departure = pickDeparture(own, free, departFrom, departTo, start);
      const arrival = pickArrival(own, free, Math.max(arriveFrom, departure ? ms(departure.at) : 0), arriveTo, end);
      if (departure || arrival) matches.push({ phoneId, departure, arrival });
    }
    // The phone with both ends matched wins; among equals, the earliest event.
    const score = (m) => (m.departure ? 1 : 0) + (m.arrival ? 1 : 0);
    const first = (m) => ms((m.departure ?? m.arrival).at);
    matches.sort((a, b) => score(b) - score(a) || first(a) - first(b));
    const match = matches[0];

    const updated = {
      ...trip,
      startAt: carStart(trip),
      endAt: trip.carEndAt ?? trip.endAt,
      phoneId: match?.phoneId ?? null,
      startLocation: null,
      endLocation: null,
    };
    for (const [event, side] of [
      [match?.departure, "start"],
      [match?.arrival, "end"],
    ]) {
      if (!event) continue;
      updated[`${side}At`] = iso(event.at);
      if (isNumber(event.lat) && isNumber(event.lon)) updated[`${side}Location`] = { lat: event.lat, lon: event.lon };
      taken.add(event);
      attachments.push({ eventId: event.id, tripId: trip.id });
    }
    const flags = (trip.flags ?? []).filter((f) => f !== "withoutPhone");
    if (!updated.phoneId) flags.push("withoutPhone");
    updated.flags = flags;
    result.push(updated);
  }
  const unattached = sorted.filter((e) => !taken.has(e));
  return { trips: result, attachments, unattached };
}

// Percent consumed between consecutive snapshots, ignoring increases (charging, refuelling).
function consumedOver(snapshots, field) {
  let used = 0;
  for (let i = 1; i < snapshots.length; i += 1) {
    const a = snapshots[i - 1][field];
    const b = snapshots[i][field];
    if (isNumber(a) && isNumber(b) && b < a) used += a - b;
  }
  return used;
}

// Compares BYD's last-50 km energy figures with the percentage drops over the same distance
// to measure the real battery capacity and tank size. One reading per /energy update; the
// value is adopted once three readings agree within 10 %, unless the person set it by hand.
export function calibrate(snapshots, energy, state = {}) {
  const next = {
    batteryReadings: [...(state.batteryReadings ?? [])],
    tankReadings: [...(state.tankReadings ?? [])],
    batteryKwh: state.batteryKwh ?? null,
    tankLitres: state.tankLitres ?? null,
    batterySource: state.batterySource ?? "model",
    tankSource: state.tankSource ?? "model",
    lastEnergyAt: state.lastEnergyAt ?? null,
  };
  const last50 = energy?.last50km;
  if (!last50 || !snapshots.length) return next;
  const stamp = energy.updatedAt ?? null;
  if (stamp && stamp === next.lastEnergyAt) return next;
  next.lastEnergyAt = stamp;

  const ordered = snapshots.map(normaliseSnapshot).sort((a, b) => ms(a.at) - ms(b.at));
  const latest = ordered[ordered.length - 1];
  const window = ordered.filter((s) => s.odometerKm >= latest.odometerKm - 50);
  if (window.length < 2 || latest.odometerKm - window[0].odometerKm < 40) return next;

  const socUsed = consumedOver(window, "batteryPercent");
  if (isNumber(last50.evKwh) && last50.evKwh > 0.5 && socUsed >= 10) {
    next.batteryReadings.push(round(last50.evKwh / (socUsed / 100), 2));
  }
  const fuelUsed = consumedOver(window, "fuelPercent");
  if (isNumber(last50.petrolLitres) && last50.petrolLitres > 1 && fuelUsed >= 5) {
    next.tankReadings.push(round(last50.petrolLitres / (fuelUsed / 100), 1));
  }
  next.batteryReadings = next.batteryReadings.slice(-10);
  next.tankReadings = next.tankReadings.slice(-10);

  const adopt = (readings) => {
    const recent = readings.slice(-CALIBRATION_READINGS);
    if (recent.length < CALIBRATION_READINGS) return null;
    const mid = median(recent);
    return recent.every((r) => Math.abs(r - mid) / mid <= CALIBRATION_TOLERANCE) ? mid : null;
  };
  const battery = adopt(next.batteryReadings);
  if (battery != null && next.batterySource !== "manual") {
    next.batteryKwh = round(battery, 1);
    next.batterySource = "measured";
  }
  const tank = adopt(next.tankReadings);
  if (tank != null && next.tankSource !== "manual") {
    next.tankLitres = round(tank, 0);
    next.tankSource = "measured";
  }
  return next;
}

// ---------------------------------------------------------------------------------------------
// Store: everything that touches SQLite. `sql` is `ctx.storage.sql` (or a node:sqlite shim in
// tests) with `exec(query, ...bindings)` returning a cursor with `toArray()`.

const PUBLIC_SETTINGS = [
  "priceKwh",
  "petrolOverrideVndPerLitre",
  "batteryKwh",
  "tankLitres",
  "batterySource",
  "tankSource",
  "notifyOnTrip",
  "chargeEfficiency",
];
const DEFAULT_SETTINGS = {
  priceKwh: null,
  petrolOverrideVndPerLitre: null,
  batteryKwh: null,
  tankLitres: null,
  batterySource: "model",
  tankSource: "model",
  notifyOnTrip: false,
  chargeEfficiency: DEFAULT_CHARGE_EFFICIENCY,
};

export class TripStore {
  constructor(sql, { now = () => new Date() } = {}) {
    this.sql = sql;
    this.now = now;
    const from = storedVersion(sql);
    migrate(sql);
    // Up to v1, kilometres the car reported late became trips of their own: cut them again once.
    if (from === 1) this.rebuild();
    // Before v4 nobody looked for charges between trips: find the ones already in the snapshots.
    else if (from >= 2 && from < 4) this.backfillCharges();
  }

  rows(query, ...bindings) {
    return this.sql.exec(query, ...bindings).toArray();
  }

  run(query, ...bindings) {
    this.sql.exec(query, ...bindings);
  }

  // Settings are one JSON value per key; keys starting with "_" are internal state.
  getSetting(key, fallback = null) {
    const row = this.rows(`SELECT value FROM settings WHERE key = ?`, key)[0];
    return row ? JSON.parse(row.value) : fallback;
  }

  setSetting(key, value) {
    this.run(
      `INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
      key,
      JSON.stringify(value ?? null),
    );
  }

  getSettings() {
    const settings = { ...DEFAULT_SETTINGS };
    for (const row of this.rows(`SELECT key, value FROM settings`)) {
      if (PUBLIC_SETTINGS.includes(row.key)) settings[row.key] = JSON.parse(row.value);
    }
    settings.evRate = this.getSetting("_evRate", DEFAULT_EV_RATE);
    return settings;
  }

  putSettings(patch) {
    for (const key of PUBLIC_SETTINGS) {
      if (!(key in patch)) continue;
      const value = patch[key];
      if (key === "batteryKwh" && isNumber(value) && value > 0) {
        this.setSetting("batteryKwh", value);
        this.setSetting("batterySource", patch.batterySource === "model" ? "model" : "manual");
      } else if (key === "tankLitres" && isNumber(value) && value > 0) {
        this.setSetting("tankLitres", value);
        this.setSetting("tankSource", patch.tankSource === "model" ? "model" : "manual");
      } else if (key === "batterySource" || key === "tankSource") {
        // Written together with the value above; on its own it can only reset to "model".
        const valueKey = key === "batterySource" ? "batteryKwh" : "tankLitres";
        if (value === "model" && !(valueKey in patch)) this.setSetting(key, "model");
      } else if (key === "chargeEfficiency") {
        if (value === null) this.setSetting(key, null);
        else if (isNumber(value) && value >= 0.5 && value <= 1) this.setSetting(key, value);
        else throw new HttpError(400, "chargeEfficiency must be between 0.5 and 1");
      } else if (key === "notifyOnTrip") {
        this.setSetting(key, Boolean(value));
      } else if (value === null || isNumber(value)) {
        this.setSetting(key, value);
      }
    }
    return this.getSettings();
  }

  // --- snapshots ---------------------------------------------------------------------------

  insertSnapshots(raws) {
    let inserted = 0;
    for (const raw of raws) {
      const s = normaliseSnapshot(raw);
      if (!isNumber(s.odometerKm) || s.odometerKm <= 0) continue;
      const before = this.rows(`SELECT 1 AS x FROM snapshots WHERE at = ?`, s.at).length;
      if (before) continue;
      this.run(
        `INSERT INTO snapshots (at, received_at, odometer_km, battery_percent, fuel_percent, range_electric_km,
           range_fuel_km, power_on, charging, source) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        s.at,
        s.receivedAt,
        s.odometerKm,
        s.batteryPercent,
        s.fuelPercent,
        s.rangeElectricKm,
        s.rangeFuelKm,
        s.powerOn ? 1 : 0,
        s.charging ? 1 : 0,
        s.source,
      );
      inserted += 1;
    }
    return inserted;
  }

  snapshotsAfter(at, limit = 5000) {
    const rows = at
      ? this.rows(`SELECT * FROM snapshots WHERE at > ? ORDER BY at LIMIT ?`, at, limit)
      : this.rows(`SELECT * FROM snapshots ORDER BY at LIMIT ?`, limit);
    return rows.map(snapshotFromRow);
  }

  lastSnapshotAt() {
    return this.rows(`SELECT MAX(at) AS at FROM snapshots`)[0]?.at ?? null;
  }

  // --- trips -------------------------------------------------------------------------------

  insertTrip(trip) {
    this.run(
      `INSERT INTO trips (id, start_at, end_at, odo_start, odo_end, soc_start, soc_end, fuel_start, fuel_end,
         kwh, litres, ev_km, petrol_km, price_kwh, price_litre, petrol_cycle, phone_id, start_lat, start_lon,
         end_lat, end_lon, flags, source, deleted_at, created_at, car_start_at, car_end_at, gap_start_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      trip.id,
      trip.startAt,
      trip.endAt,
      trip.odoStart,
      trip.odoEnd,
      trip.socStart ?? null,
      trip.socEnd ?? null,
      trip.fuelStart ?? null,
      trip.fuelEnd ?? null,
      trip.kwh,
      trip.litres,
      trip.evKm,
      trip.petrolKm,
      trip.priceKwh ?? null,
      trip.priceLitre ?? null,
      trip.petrolCycle ?? null,
      trip.phoneId ?? null,
      trip.startLocation?.lat ?? null,
      trip.startLocation?.lon ?? null,
      trip.endLocation?.lat ?? null,
      trip.endLocation?.lon ?? null,
      JSON.stringify(trip.flags ?? []),
      trip.source ?? "car",
      trip.deletedAt ?? null,
      this.now().toISOString(),
      trip.carStartAt ?? trip.startAt,
      trip.carEndAt ?? trip.endAt,
      trip.gapStartAt ?? null,
    );
  }

  updateTripAttachment(trip) {
    this.run(
      `UPDATE trips SET start_at = ?, end_at = ?, phone_id = ?, start_lat = ?, start_lon = ?, end_lat = ?, end_lon = ?,
         flags = ? WHERE id = ?`,
      trip.startAt,
      trip.endAt,
      trip.phoneId ?? null,
      trip.startLocation?.lat ?? null,
      trip.startLocation?.lon ?? null,
      trip.endLocation?.lat ?? null,
      trip.endLocation?.lon ?? null,
      JSON.stringify(trip.flags ?? []),
      trip.id,
    );
  }

  tripRows({ since = null, limit = 200, includeDeleted = false } = {}) {
    let rows;
    // Old trips changed in place (re-priced) since the client's last pull: send them all again.
    const changedAt = this.getSetting("_tripsChangedAt", null);
    if (since && changedAt && since < changedAt) since = null;
    if (since) {
      rows = this.rows(
        `SELECT t.*, p.name AS phone_name FROM trips t LEFT JOIN phones p ON p.id = t.phone_id
         WHERE t.end_at >= ? OR t.created_at >= ? OR (t.deleted_at IS NOT NULL AND t.deleted_at >= ?)
         ORDER BY t.end_at DESC LIMIT ?`,
        since,
        since,
        since,
        limit,
      );
    } else {
      rows = this.rows(
        `SELECT t.*, p.name AS phone_name FROM trips t LEFT JOIN phones p ON p.id = t.phone_id
         ${includeDeleted ? "" : "WHERE t.deleted_at IS NULL"} ORDER BY t.end_at DESC LIMIT ?`,
        limit,
      );
    }
    return rows.map(tripFromRow);
  }

  listTrips({ since = null, limit = 200 } = {}) {
    const trips = this.tripRows({ since, limit, includeDeleted: Boolean(since) });
    return {
      trips: trips.map(publicTrip),
      charges: this.chargeRows({ since, limit }),
      openTrip: this.openTripPublic(),
      settings: this.getSettings(),
      prices: this.getSetting("_prices", null),
      energy: this.getSetting("_energy", null),
      serverTime: this.now().toISOString(),
    };
  }

  openTripPublic() {
    const cursor = this.getSetting("_cursor", {});
    const open = cursor.openTrip;
    if (!open) return null;
    const last = open.lastSnapshot;
    return {
      startAt: open.startAt,
      odoStart: open.odoStart,
      socStart: open.socStart,
      fuelStart: open.fuelStart,
      km: last ? Math.max(0, last.odometerKm - open.odoStart) : 0,
      lastSeenAt: last?.at ?? open.startAt,
    };
  }

  deleteTrip(id) {
    const exists = this.rows(`SELECT 1 AS x FROM trips WHERE id = ?`, id).length;
    if (!exists) return false;
    this.run(`UPDATE trips SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL`, this.now().toISOString(), id);
    return true;
  }

  /// Stores what a refuel ("fuel", litres) or a charge on the way ("charge", kWh) really came to,
  /// and what it cost in dong; null for both goes back to the app's estimate.
  editRefill(id, { kind, amount = null, cost = null } = {}) {
    if (kind !== "fuel" && kind !== "charge") throw new HttpError(400, 'kind must be "fuel" or "charge"');
    for (const value of [amount, cost]) {
      if (value !== null && !(isNumber(value) && value > 0)) {
        throw new HttpError(400, "amount and cost must be positive numbers or null");
      }
    }
    const row = this.rows(`SELECT refills FROM trips WHERE id = ?`, id)[0];
    if (!row) return null;
    const refills = row.refills ? JSON.parse(row.refills) : {};
    if (amount === null && cost === null) delete refills[kind];
    else refills[kind] = { amount, cost };
    const stored = Object.keys(refills).length ? JSON.stringify(refills) : null;
    this.run(`UPDATE trips SET refills = ? WHERE id = ?`, stored, id);
    this.setSetting("_tripsChangedAt", this.now().toISOString());
    return publicTrip(this.tripRow(id));
  }

  tripRow(id) {
    const rows = this.rows(
      `SELECT t.*, p.name AS phone_name FROM trips t LEFT JOIN phones p ON p.id = t.phone_id WHERE t.id = ?`,
      id,
    );
    return rows.length ? tripFromRow(rows[0]) : null;
  }

  // --- charges between trips ------------------------------------------------------------------

  // Prices a charge as it is found: the charger's kWh from the battery's rise, the battery size
  // and the charging efficiency of the day, at the day's electricity price.
  insertCharge(charge, settings = this.getSettings()) {
    const batteryKwh = settings.batteryKwh;
    const efficiency = settings.chargeEfficiency ?? DEFAULT_CHARGE_EFFICIENCY;
    const kwh = isNumber(batteryKwh) ? round(((charge.socEnd - charge.socStart) / 100) * batteryKwh / efficiency) : null;
    const now = this.now().toISOString();
    this.run(
      `INSERT INTO charges (id, parked_at, start_at, end_at, odometer_km, soc_start, soc_end, charging_seen, kwh,
         price_kwh, edit, deleted_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      charge.id,
      charge.parkedAt,
      charge.startAt,
      charge.endAt,
      charge.odometerKm,
      charge.socStart,
      charge.socEnd,
      charge.chargingSeen ? 1 : 0,
      kwh,
      isNumber(settings.priceKwh) ? settings.priceKwh : null,
      charge.edit ? JSON.stringify(charge.edit) : null,
      charge.deletedAt ?? null,
      now,
      now,
    );
  }

  chargeRows({ since = null, limit = 200 } = {}) {
    const changedAt = this.getSetting("_tripsChangedAt", null);
    if (since && changedAt && since < changedAt) since = null;
    const rows = since
      ? this.rows(
          `SELECT * FROM charges WHERE end_at >= ? OR updated_at >= ? OR (deleted_at IS NOT NULL AND deleted_at >= ?)
           ORDER BY end_at DESC LIMIT ?`,
          since,
          since,
          since,
          limit,
        )
      : this.rows(`SELECT * FROM charges WHERE deleted_at IS NULL ORDER BY end_at DESC LIMIT ?`, limit);
    return rows.map(chargeFromRow);
  }

  /// Stores what a charge really came to (kWh from the charger, dong paid); null for both goes
  /// back to the estimate.
  editCharge(id, { amount = null, cost = null } = {}) {
    for (const value of [amount, cost]) {
      if (value !== null && !(isNumber(value) && value > 0)) {
        throw new HttpError(400, "amount and cost must be positive numbers or null");
      }
    }
    if (!this.rows(`SELECT 1 AS x FROM charges WHERE id = ?`, id).length) return null;
    const edit = amount === null && cost === null ? null : JSON.stringify({ amount, cost });
    this.run(`UPDATE charges SET edit = ?, updated_at = ? WHERE id = ?`, edit, this.now().toISOString(), id);
    return chargeFromRow(this.rows(`SELECT * FROM charges WHERE id = ?`, id)[0]);
  }

  deleteCharge(id) {
    if (!this.rows(`SELECT 1 AS x FROM charges WHERE id = ?`, id).length) return false;
    const now = this.now().toISOString();
    this.run(`UPDATE charges SET deleted_at = ?, updated_at = ? WHERE id = ? AND deleted_at IS NULL`, now, now, id);
    return true;
  }

  // Finds the charges in every stored snapshot, without touching the trips, and leaves the
  // cursor knowing where the car stands now. Charges already stored at the same odometer stay.
  backfillCharges() {
    const cursor = this.getSetting("_cursor", {});
    if (!cursor.lastAt) return 0;
    const snapshots = this.rows(`SELECT * FROM snapshots WHERE at <= ? ORDER BY at`, cursor.lastAt).map(snapshotFromRow);
    const result = deriveTrips(snapshots);
    const known = new Set(this.rows(`SELECT odometer_km FROM charges`).map((r) => r.odometer_km));
    const settings = this.getSettings();
    let inserted = 0;
    for (const charge of result.charges) {
      if (known.has(charge.odometerKm)) continue;
      this.insertCharge(charge, settings);
      inserted += 1;
    }
    this.setSetting("_cursor", { ...cursor, parked: result.parked });
    return inserted;
  }

  /// Corrects a mistyped electricity price on stored trips: every trip priced at `fromPriceKwh`
  /// is re-priced at `toPriceKwh`. Trips priced at any other rate keep theirs.
  repriceTrips({ fromPriceKwh, toPriceKwh } = {}) {
    if (!isNumber(fromPriceKwh) || !isNumber(toPriceKwh) || fromPriceKwh <= 0 || toPriceKwh <= 0) {
      throw new HttpError(400, "fromPriceKwh and toPriceKwh must be positive numbers");
    }
    const [{ n }] = this.rows(`SELECT COUNT(*) AS n FROM trips WHERE price_kwh = ?`, fromPriceKwh);
    const [{ n: charges }] = this.rows(`SELECT COUNT(*) AS n FROM charges WHERE price_kwh = ?`, fromPriceKwh);
    if (n > 0) this.run(`UPDATE trips SET price_kwh = ? WHERE price_kwh = ?`, toPriceKwh, fromPriceKwh);
    if (charges > 0) this.run(`UPDATE charges SET price_kwh = ? WHERE price_kwh = ?`, toPriceKwh, fromPriceKwh);
    if (n > 0 || charges > 0) this.setSetting("_tripsChangedAt", this.now().toISOString());
    return { updated: n, charges };
  }

  // --- phones and events -------------------------------------------------------------------

  touchPhone(phoneId, phoneName) {
    if (!phoneId) return;
    this.run(
      `INSERT INTO phones (id, name, last_seen) VALUES (?, ?, ?)
       ON CONFLICT(id) DO UPDATE SET name = COALESCE(excluded.name, phones.name), last_seen = excluded.last_seen`,
      phoneId,
      phoneName ?? null,
      this.now().toISOString(),
    );
  }

  postEvents({ phoneId, phoneName, events = [] }) {
    if (!phoneId) throw new HttpError(400, "phoneId required");
    this.touchPhone(phoneId, phoneName);
    for (const event of events) {
      if (!["departure", "arrival"].includes(event.kind) || !event.at) continue;
      this.run(
        `INSERT OR IGNORE INTO phone_events (phone_id, kind, at, lat, lon) VALUES (?, ?, ?, ?, ?)`,
        phoneId,
        event.kind,
        iso(event.at),
        isNumber(event.lat) ? event.lat : null,
        isNumber(event.lon) ? event.lon : null,
      );
    }
    return { attached: this.attachPendingEvents() };
  }

  // Re-matches every recent event to every recent trip, so a late event can still move a
  // trip's ends or hand it to another phone. Only rows whose outcome changed are written.
  attachPendingEvents() {
    const horizon = new Date(this.now().getTime() - EVENT_RETENTION_DAYS * 86400000).toISOString();
    const events = this.rows(`SELECT * FROM phone_events WHERE at >= ? ORDER BY at`, horizon).map((r) => ({
      id: r.id,
      phoneId: r.phone_id,
      kind: r.kind,
      at: r.at,
      lat: r.lat,
      lon: r.lon,
      tripId: r.trip_id,
    }));
    const trips = this.rows(`SELECT * FROM trips WHERE deleted_at IS NULL AND end_at >= ? ORDER BY start_at`, horizon).map(
      tripFromRow,
    );
    if (!trips.length) return 0;
    const result = attachEvents(trips, events);
    const before = new Map(trips.map((t) => [t.id, t]));
    const fields = (t) =>
      JSON.stringify([t.startAt, t.endAt, t.phoneId ?? null, t.startLocation ?? null, t.endLocation ?? null, t.flags]);
    for (const trip of result.trips) {
      if (fields(trip) !== fields(before.get(trip.id))) this.updateTripAttachment(trip);
    }
    const ids = [...before.keys()];
    this.run(
      `UPDATE phone_events SET trip_id = NULL WHERE trip_id IN (${ids.map(() => "?").join(", ")})`,
      ...ids,
    );
    const previous = new Map(events.map((e) => [e.id, e.tripId]));
    let moved = 0;
    for (const { eventId, tripId } of result.attachments) {
      this.run(`UPDATE phone_events SET trip_id = ? WHERE id = ?`, tripId, eventId);
      if (previous.get(eventId) !== tripId) moved += 1;
    }
    return moved;
  }

  // Derives every trip again from the stored snapshots, after a change to how trips are cut.
  // The old rows are soft-deleted so the app drops them on its next refresh; a new trip that
  // ends where one the person deleted ended stays deleted. Charges are found again the same
  // way, keeping the corrections and deletions made at the same odometer reading.
  rebuild() {
    const now = this.now().toISOString();
    const deletedEnds = new Set(
      this.rows(`SELECT odo_end FROM trips WHERE deleted_at IS NOT NULL`).map((r) => r.odo_end),
    );
    const replaced = this.rows(`SELECT COUNT(*) AS n FROM trips WHERE deleted_at IS NULL`)[0].n;
    const chargeEdits = this.rows(`SELECT odometer_km, edit FROM charges WHERE deleted_at IS NULL AND edit IS NOT NULL`);
    const deletedCharges = this.rows(
      `SELECT odometer_km FROM charges WHERE deleted_at IS NOT NULL AND odometer_km NOT IN
         (SELECT odometer_km FROM charges WHERE deleted_at IS NULL)`,
    );
    this.run(`UPDATE trips SET deleted_at = ? WHERE deleted_at IS NULL`, now);
    this.run(`UPDATE charges SET deleted_at = ?, updated_at = ? WHERE deleted_at IS NULL`, now, now);
    this.run(`UPDATE phone_events SET trip_id = NULL`);
    this.setSetting("_cursor", {});
    const trips = this.deriveNewTrips();
    for (const odoEnd of deletedEnds) {
      this.run(`UPDATE trips SET deleted_at = ? WHERE deleted_at IS NULL AND odo_end = ?`, now, odoEnd);
    }
    for (const { odometer_km, edit } of chargeEdits) {
      this.run(`UPDATE charges SET edit = ? WHERE deleted_at IS NULL AND odometer_km = ?`, edit, odometer_km);
    }
    for (const { odometer_km } of deletedCharges) {
      this.run(`UPDATE charges SET deleted_at = ? WHERE deleted_at IS NULL AND odometer_km = ?`, now, odometer_km);
    }
    const attached = this.attachPendingEvents();
    return { replaced, trips, attached };
  }

  getPhones() {
    const phones = this.rows(`SELECT id, name, last_seen FROM phones ORDER BY last_seen DESC`).map((r) => ({
      id: r.id,
      name: r.name,
      lastSeen: r.last_seen,
    }));
    return { phones, leader: this.leader("car") };
  }

  // --- leases ------------------------------------------------------------------------------

  leader(kind) {
    const row = this.rows(
      `SELECT l.phone_id, l.until, p.name FROM leases l LEFT JOIN phones p ON p.id = l.phone_id WHERE l.kind = ?`,
      kind,
    )[0];
    if (!row || ms(row.until) <= this.now().getTime()) return null;
    return { phoneId: row.phone_id, name: row.name ?? null, until: row.until };
  }

  lease({ phoneId, phoneName, kind = "car", ttlSeconds = 120 }) {
    if (!phoneId) throw new HttpError(400, "phoneId required");
    this.touchPhone(phoneId, phoneName);
    const current = this.leader(kind);
    if (current && current.phoneId !== phoneId) return { granted: false, leader: current };
    const ttl = Math.min(Math.max(Number(ttlSeconds) || 120, 10), 3600);
    const until = new Date(this.now().getTime() + ttl * 1000).toISOString();
    this.run(
      `INSERT INTO leases (kind, phone_id, until) VALUES (?, ?, ?)
       ON CONFLICT(kind) DO UPDATE SET phone_id = excluded.phone_id, until = excluded.until`,
      kind,
      phoneId,
      until,
    );
    return { granted: true, leader: this.leader(kind) };
  }

  // --- sync from the container -------------------------------------------------------------

  // `fetchJson(path)` resolves to the parsed body or null when the container did not answer.
  async sync(fetchJson) {
    const report = { snapshots: 0, trips: 0, attached: 0, prices: false, energy: false };
    const lastAt = this.lastSnapshotAt();
    const since = lastAt ? `?since=${encodeURIComponent(lastAt)}` : "";
    const [snapshotBody, prices] = await Promise.all([fetchJson(`/snapshots${since}`), fetchJson("/prices")]);

    if (prices && typeof prices === "object") {
      this.setSetting("_prices", { ...prices, syncedAt: this.now().toISOString() });
      report.prices = true;
      const hint = prices.capacityHint;
      if (hint) {
        if (this.getSetting("batteryKwh") == null && isNumber(hint.batteryKwh)) {
          this.setSetting("batteryKwh", hint.batteryKwh);
          this.setSetting("batterySource", "model");
        }
        if (this.getSetting("tankLitres") == null && isNumber(hint.tankLitres)) {
          this.setSetting("tankLitres", hint.tankLitres);
          this.setSetting("tankSource", "model");
        }
      }
    }

    if (Array.isArray(snapshotBody?.snapshots)) {
      report.snapshots = this.insertSnapshots(snapshotBody.snapshots);
    }
    report.trips = this.deriveNewTrips();
    report.attached = this.attachPendingEvents();

    const lastEnergyPoll = this.getSetting("_energyPolledAt", null);
    if (!lastEnergyPoll || this.now().getTime() - ms(lastEnergyPoll) >= ENERGY_INTERVAL_MS) {
      this.setSetting("_energyPolledAt", this.now().toISOString());
      const energy = await fetchJson("/energy");
      if (energy?.last50km) {
        this.setSetting("_energy", energy);
        report.energy = true;
        this.runCalibration(energy);
      }
    }
    return report;
  }

  deriveNewTrips() {
    const cursor = this.getSetting("_cursor", {});
    const snapshots = this.snapshotsAfter(cursor.lastAt ?? null);
    if (!snapshots.length) return 0;
    const result = deriveTrips(snapshots, cursor.openTrip ?? null, cursor.prev ?? null, cursor.parked ?? null);
    const settings = this.getSettings();
    const prices = this.getSetting("_prices", null);
    for (const raw of result.trips) {
      const trip = computeTrip(raw, settings, prices);
      this.insertTrip(trip);
    }
    for (const charge of result.charges) this.insertCharge(charge, settings);
    if (result.trips.length) {
      const recent = this.tripRows({ limit: 100 });
      this.setSetting("_evRate", round(learnEvRate(recent), 3));
    }
    this.setSetting("_cursor", {
      lastAt: snapshots[snapshots.length - 1].at,
      openTrip: result.openTrip,
      prev: result.prev,
      parked: result.parked,
    });
    return result.trips.length;
  }

  runCalibration(energy) {
    const state = {
      batteryReadings: this.getSetting("_batteryReadings", []),
      tankReadings: this.getSetting("_tankReadings", []),
      batteryKwh: this.getSetting("batteryKwh"),
      tankLitres: this.getSetting("tankLitres"),
      batterySource: this.getSetting("batterySource", "model"),
      tankSource: this.getSetting("tankSource", "model"),
      lastEnergyAt: this.getSetting("_lastEnergyAt"),
    };
    const snapshots = this.rows(`SELECT * FROM snapshots ORDER BY at DESC LIMIT 400`).map(snapshotFromRow).reverse();
    const next = calibrate(snapshots, energy, state);
    this.setSetting("_batteryReadings", next.batteryReadings);
    this.setSetting("_tankReadings", next.tankReadings);
    this.setSetting("_lastEnergyAt", next.lastEnergyAt);
    if (next.batteryKwh != null) this.setSetting("batteryKwh", next.batteryKwh);
    if (next.tankLitres != null) this.setSetting("tankLitres", next.tankLitres);
    this.setSetting("batterySource", next.batterySource);
    this.setSetting("tankSource", next.tankSource);
    return next;
  }

  // --- HTTP ----------------------------------------------------------------------------------

  // Answers the trip-log routes; returns null for anything the container should serve.
  async handle(request) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const method = request.method.toUpperCase();
    try {
      if (path === "/trips" && method === "GET") {
        const since = url.searchParams.get("since");
        const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 200, 1), 1000);
        return json(this.listTrips({ since: since ? iso(since) : null, limit }));
      }
      if (path === "/trips/events" && method === "POST") {
        return json(this.postEvents(await request.json()));
      }
      if (path === "/trips/sync" && method === "POST") {
        return null; // handled by the Durable Object, which knows how to reach the container
      }
      const tripMatch = path.match(/^\/trips\/([^/]+)$/);
      const refillMatch = path.match(/^\/trips\/([^/]+)\/refill$/);
      if (refillMatch && method === "PUT") {
        const trip = this.editRefill(refillMatch[1], await request.json());
        return trip ? json(trip) : json({ detail: "No such trip" }, 404);
      }
      if (tripMatch && method === "DELETE") {
        if (!this.deleteTrip(tripMatch[1])) return json({ detail: "No such trip" }, 404);
        return json({ deleted: tripMatch[1] });
      }
      const chargeMatch = path.match(/^\/charges\/([^/]+)$/);
      if (chargeMatch && method === "PUT") {
        const charge = this.editCharge(chargeMatch[1], await request.json());
        return charge ? json(charge) : json({ detail: "No such charge" }, 404);
      }
      if (chargeMatch && method === "DELETE") {
        if (!this.deleteCharge(chargeMatch[1])) return json({ detail: "No such charge" }, 404);
        return json({ deleted: chargeMatch[1] });
      }
      if (path === "/trips/reprice" && method === "POST") {
        return json(this.repriceTrips(await request.json()));
      }
      if (path === "/settings" && method === "GET") return json(this.getSettings());
      if (path === "/settings" && method === "PUT") return json(this.putSettings(await request.json()));
      if (path === "/phones" && method === "GET") return json(this.getPhones());
      if (path === "/lease" && method === "POST") return json(this.lease(await request.json()));
      if (["/trips", "/trips/events", "/trips/reprice", "/settings", "/phones", "/lease"].includes(path) || tripMatch || refillMatch || chargeMatch) {
        return json({ detail: "Method not allowed" }, 405);
      }
      return null;
    } catch (error) {
      if (error instanceof HttpError) return json({ detail: error.message }, error.status);
      if (error instanceof SyntaxError) return json({ detail: "Bad JSON body" }, 400);
      throw error;
    }
  }
}

export class HttpError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

function snapshotFromRow(r) {
  return {
    at: r.at,
    receivedAt: r.received_at,
    odometerKm: r.odometer_km,
    batteryPercent: r.battery_percent,
    fuelPercent: r.fuel_percent,
    rangeElectricKm: r.range_electric_km,
    rangeFuelKm: r.range_fuel_km,
    powerOn: Boolean(r.power_on),
    charging: Boolean(r.charging),
    source: r.source,
  };
}

function tripFromRow(r) {
  return {
    id: r.id,
    startAt: r.start_at,
    endAt: r.end_at,
    odoStart: r.odo_start,
    odoEnd: r.odo_end,
    socStart: r.soc_start,
    socEnd: r.soc_end,
    fuelStart: r.fuel_start,
    fuelEnd: r.fuel_end,
    km: round(r.odo_end - r.odo_start, 1),
    kwh: r.kwh,
    litres: r.litres,
    evKm: r.ev_km,
    petrolKm: r.petrol_km,
    priceKwh: r.price_kwh,
    priceLitre: r.price_litre,
    petrolCycle: r.petrol_cycle,
    phoneId: r.phone_id,
    phoneName: r.phone_name ?? null,
    startLocation: r.start_lat != null ? { lat: r.start_lat, lon: r.start_lon } : null,
    endLocation: r.end_lat != null ? { lat: r.end_lat, lon: r.end_lon } : null,
    flags: JSON.parse(r.flags || "[]"),
    source: r.source,
    deletedAt: r.deleted_at,
    createdAt: r.created_at,
    carStartAt: r.car_start_at ?? r.start_at,
    carEndAt: r.car_end_at ?? r.end_at,
    gapStartAt: r.gap_start_at,
    refills: r.refills ? JSON.parse(r.refills) : null,
  };
}

function chargeFromRow(r) {
  return {
    id: r.id,
    parkedAt: r.parked_at,
    startAt: r.start_at,
    endAt: r.end_at,
    odometerKm: r.odometer_km,
    socStart: r.soc_start,
    socEnd: r.soc_end,
    chargingSeen: Boolean(r.charging_seen),
    kwh: r.kwh,
    priceKwh: r.price_kwh,
    edit: r.edit ? JSON.parse(r.edit) : null,
    deletedAt: r.deleted_at,
  };
}

function publicTrip(t) {
  const km = t.km;
  const electricShare = km > 0 && t.evKm != null ? round(t.evKm / km, 3) : null;
  const cost =
    t.priceKwh != null && t.priceLitre != null && km > 0
      ? (() => {
          const total = Math.round((t.kwh ?? 0) * t.priceKwh + (t.litres ?? 0) * t.priceLitre);
          return { total, perKm: Math.round(total / km), priceKwh: t.priceKwh, priceLitre: t.priceLitre, petrolCycle: t.petrolCycle };
        })()
      : null;
  return {
    id: t.id,
    startAt: t.startAt,
    endAt: t.endAt,
    km,
    odoStart: t.odoStart,
    odoEnd: t.odoEnd,
    socStart: t.socStart,
    socEnd: t.socEnd,
    fuelStart: t.fuelStart,
    fuelEnd: t.fuelEnd,
    kwh: t.kwh,
    litres: t.litres,
    evKm: t.evKm,
    petrolKm: t.petrolKm,
    electricShare,
    cost,
    phoneId: t.phoneId,
    phoneName: t.phoneName,
    startLocation: t.startLocation,
    endLocation: t.endLocation,
    flags: t.flags,
    source: t.source,
    deletedAt: t.deletedAt,
    refills: t.refills ?? null,
  };
}
