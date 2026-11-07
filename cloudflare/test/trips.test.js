import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import {
  DEFAULT_EV_RATE,
  TripStore,
  attachEvents,
  calibrate,
  computeTrip,
  deriveTrips,
  learnEvRate,
  migrate,
} from "../src/trips.js";

// Stands in for ctx.storage.sql: exec(query, ...bindings) → cursor with toArray().
function memorySql() {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query, ...bindings) {
      const rows = db.prepare(query).all(...bindings.map((b) => (b === undefined ? null : b)));
      return { toArray: () => rows, one: () => rows[0] };
    },
  };
}

const T0 = Date.UTC(2026, 10, 4, 8, 0, 0); // 4 Nov 2026 08:00Z
const at = (minutes) => new Date(T0 + minutes * 60000).toISOString();
const snap = (minutes, odometerKm, batteryPercent, fuelPercent, powerOn, extra = {}) => ({
  at: at(minutes),
  receivedAt: at(minutes),
  odometerKm,
  batteryPercent,
  fuelPercent,
  rangeElectricKm: null,
  rangeFuelKm: null,
  powerOn,
  charging: false,
  source: "push",
  ...extra,
});

const settings = { batteryKwh: 18.3, tankLitres: 60, evRate: DEFAULT_EV_RATE, priceKwh: 3700 };
const prices = { petrol: { vndPerLitre: 23230, cycle: "2026-10-30" } };

test("pure-EV trip: power-on → power-off pair, kWh from the SoC drop, no petrol", () => {
  const { trips, openTrip } = deriveTrips([snap(0, 1000, 80, 50, true), snap(30, 1020, 60, 50, false)]);
  assert.equal(trips.length, 1);
  assert.equal(openTrip, null);
  const trip = computeTrip(trips[0], settings, prices);
  assert.equal(trip.km, 20);
  assert.equal(trip.kwh, 3.66);
  assert.equal(trip.litres, 0);
  assert.equal(trip.evKm, 20);
  assert.equal(trip.petrolKm, 0);
  assert.equal(trip.electricShare, 1);
  assert.equal(trip.source, "car");
  assert.deepEqual(trip.flags, ["withoutPhone"]);
  assert.equal(trip.cost.total, Math.round(3.66 * 3700));
  assert.equal(trip.cost.priceLitre, 23230);
  assert.equal(trip.cost.petrolCycle, "2026-10-30");
});

test("petrol-only trip: litres from the fuel drop, all petrol km", () => {
  const { trips } = deriveTrips([snap(0, 1000, 20, 50, true), snap(60, 1060, 20, 44, false)]);
  const trip = computeTrip(trips[0], settings, prices);
  assert.equal(trip.km, 60);
  assert.equal(trip.kwh, 0);
  assert.equal(trip.litres, 3.6);
  assert.equal(trip.evKm, 0);
  assert.equal(trip.petrolKm, 60);
  assert.equal(trip.electricShare, 0);
  assert.equal(trip.cost.total, Math.round(3.6 * 23230));
});

test("mixed trip splits the distance with the learnt EV rate", () => {
  const { trips } = deriveTrips([snap(0, 1000, 60, 50, true), snap(90, 1100, 20, 45, false)]);
  const trip = computeTrip(trips[0], settings, prices);
  assert.equal(trip.km, 100);
  assert.equal(trip.kwh, 7.32);
  assert.equal(trip.litres, 3);
  assert.equal(trip.evKm, 43.1); // 7.32 / 0.17
  assert.equal(trip.petrolKm, 56.9);
  assert.equal(trip.electricShare, 0.431);
  assert.equal(trip.cost.total, Math.round(7.32 * 3700 + 3 * 23230));
  assert.equal(trip.cost.perKm, Math.round(trip.cost.total / 100));
});

test("charged mid-trip: SoC rises, kWh clamps to zero and the trip is flagged", () => {
  const { trips } = deriveTrips([
    snap(0, 1000, 30, 50, true),
    snap(20, 1010, 25, 50, true, { charging: true }),
    snap(80, 1030, 70, 50, false),
  ]);
  const trip = computeTrip(trips[0], settings, prices);
  assert.equal(trip.kwh, 0);
  assert.ok(trip.flags.includes("chargedDuringTrip"));
  assert.ok(!trip.flags.includes("tooShortToMeasure"));
  // Charged trips never teach the EV rate.
  assert.equal(learnEvRate([{ ...trip, km: 30 }]), DEFAULT_EV_RATE);
});

test("refuelled during trip and too-short trips are flagged", () => {
  const refuelled = computeTrip(deriveTrips([snap(0, 1000, 50, 20, true), snap(30, 1015, 50, 90, false)]).trips[0], settings);
  assert.ok(refuelled.flags.includes("refuelledDuringTrip"));
  const short = computeTrip(deriveTrips([snap(0, 1000, 50, 50, true), snap(5, 1001, 50, 50, false)]).trips[0], settings, prices);
  assert.ok(short.flags.includes("tooShortToMeasure"));
  assert.equal(short.cost.total, 0);
});

test("zero-km power cycles are dropped and an open trip survives between batches", () => {
  const first = deriveTrips([snap(0, 1000, 50, 50, true), snap(2, 1000, 50, 50, false), snap(10, 1000, 50, 50, true)]);
  assert.equal(first.trips.length, 0);
  assert.ok(first.openTrip);
  assert.equal(first.openTrip.odoStart, 1000);
  const second = deriveTrips([snap(15, 1004, 48, 50, true), snap(25, 1012, 46, 50, false)], first.openTrip, first.prev);
  assert.equal(second.trips.length, 1);
  assert.equal(second.trips[0].startAt, at(10));
  assert.equal(second.trips[0].odoEnd, 1012);
  assert.equal(second.openTrip, null);
});

test("odometer jump between two power-off reports becomes a coarse trip", () => {
  const { trips } = deriveTrips([snap(0, 1000, 60, 50, false), snap(120, 1035, 40, 50, false)]);
  assert.equal(trips.length, 1);
  assert.equal(trips[0].source, "coarse");
  assert.equal(trips[0].startAt, at(0));
  assert.equal(trips[0].endAt, at(120));
  assert.equal(computeTrip(trips[0], settings).km, 35);
});

test("kilometres before a late power-on report belong to the trip it opens", () => {
  const { trips } = deriveTrips([snap(0, 1000, 60, 50, false), snap(120, 1035, 40, 49, true), snap(150, 1050, 30, 48, false)]);
  assert.equal(trips.length, 1);
  const [trip] = trips;
  assert.deepEqual([trip.source, trip.odoStart, trip.odoEnd, trip.socStart, trip.fuelStart], ["car", 1000, 1050, 60, 50]);
  assert.equal(trip.startAt, at(120));
  assert.equal(trip.gapStartAt, at(0));
});

test("a hybrid's battery rising while driving is not charging", () => {
  const { trips } = deriveTrips([snap(0, 1000, 34, 6, true), snap(17, 1002, 36, 5, false)]);
  const trip = computeTrip(trips[0], settings, prices);
  assert.ok(!trip.flags.includes("chargedDuringTrip"));
  assert.equal(trip.kwh, 0);
  assert.equal(trip.litres, 0.6);
});

test("no cost without both prices", () => {
  const trip = deriveTrips([snap(0, 1000, 60, 50, true), snap(30, 1020, 50, 50, false)]).trips[0];
  assert.equal(computeTrip(trip, { ...settings, priceKwh: null }, prices).cost, null);
  assert.equal(computeTrip(trip, settings, null).cost, null);
  const override = computeTrip(trip, { ...settings, petrolOverrideVndPerLitre: 25000 }, prices);
  assert.equal(override.cost.priceLitre, 25000);
  assert.equal(override.cost.petrolCycle, null);
});

test("learnEvRate takes the median of all-electric trips of 5 km or more", () => {
  const trips = [
    { km: 10, kwh: 1.5, litres: 0, flags: [] },
    { km: 20, kwh: 4, litres: 0, flags: [] },
    { km: 30, kwh: 3.6, litres: 0, flags: [] },
    { km: 3, kwh: 9, litres: 0, flags: [] }, // too short
    { km: 50, kwh: 5, litres: 2, flags: [] }, // used petrol
  ];
  assert.equal(learnEvRate(trips), 0.15);
});

test("two phones with overlapping events each attach to their own trip", () => {
  const trips = [
    { id: "t1", startAt: at(0), endAt: at(30), phoneId: null, flags: ["withoutPhone"] },
    { id: "t2", startAt: at(40), endAt: at(70), phoneId: null, flags: ["withoutPhone"] },
  ];
  const events = [
    { id: 1, phoneId: "A", kind: "departure", at: at(-2), lat: 10.8, lon: 106.6 },
    { id: 2, phoneId: "A", kind: "arrival", at: at(31), lat: 10.9, lon: 106.7 },
    { id: 3, phoneId: "B", kind: "departure", at: at(1) }, // also in the car on trip 1
    { id: 4, phoneId: "B", kind: "arrival", at: at(69), lat: 11, lon: 106.8 },
    { id: 5, phoneId: "B", kind: "departure", at: at(200) }, // no trip yet: kept for later
  ];
  const result = attachEvents(trips, events);
  const t1 = result.trips.find((t) => t.id === "t1");
  const t2 = result.trips.find((t) => t.id === "t2");
  assert.equal(t1.phoneId, "A"); // A matched both ends of trip 1, B only the departure
  assert.equal(t1.startAt, at(-2));
  assert.equal(t1.endAt, at(31));
  assert.deepEqual(t1.startLocation, { lat: 10.8, lon: 106.6 });
  assert.deepEqual(t1.flags, []);
  assert.equal(t2.phoneId, "B");
  assert.equal(t2.endAt, at(69));
  assert.equal(t2.startAt, at(40)); // no departure for trip 2: the car's start stays
  assert.deepEqual(
    result.attachments.map((a) => a.eventId).sort(),
    [1, 2, 4],
  );
  assert.deepEqual(result.unattached.map((e) => e.id), [3, 5]);
});

test("events farther than 15 minutes from any trip stay unattached", () => {
  const trips = [{ id: "t1", startAt: at(0), endAt: at(30), phoneId: null, flags: [] }];
  const result = attachEvents(trips, [{ id: 1, phoneId: "A", kind: "arrival", at: at(50) }]);
  assert.equal(result.attachments.length, 0);
  assert.equal(result.unattached.length, 1);
  assert.deepEqual(result.trips[0].flags, ["withoutPhone"]);
});

test("rematching uses the car's times, so a later event never drags an end further", () => {
  const trips = [{ id: "t1", startAt: at(0), endAt: at(30), carStartAt: at(0), carEndAt: at(30), phoneId: null, flags: [] }];
  const events = [
    { id: 1, phoneId: "A", kind: "departure", at: at(-5) },
    { id: 2, phoneId: "A", kind: "departure", at: at(10) }, // link came back mid-trip
  ];
  const first = attachEvents(trips, events);
  assert.equal(first.trips[0].startAt, at(-5));
  // Run again on the stored, already-adjusted trip: the start stays put.
  const again = attachEvents(first.trips, events.map((e) => ({ ...e, tripId: e.id === 1 ? "t1" : null })));
  assert.equal(again.trips[0].startAt, at(-5));
});

test("link flapping while parking resolves to the last arrival and no departure", () => {
  const trips = [
    { id: "t1", startAt: at(0), endAt: at(30), phoneId: null, flags: [] },
    { id: "t2", startAt: at(200), endAt: at(220), gapStartAt: at(30), phoneId: null, flags: [] },
  ];
  const events = [
    { id: 1, phoneId: "A", kind: "departure", at: at(1) },
    { id: 2, phoneId: "A", kind: "arrival", at: at(28) },
    { id: 3, phoneId: "A", kind: "departure", at: at(29) }, // walking past the car
    { id: 4, phoneId: "A", kind: "arrival", at: at(29.5) },
    { id: 5, phoneId: "A", kind: "departure", at: at(160) }, // real start, before the late report
    { id: 6, phoneId: "A", kind: "arrival", at: at(215) },
  ];
  const result = attachEvents(trips, events);
  const [t1, t2] = result.trips;
  assert.deepEqual([t1.startAt, t1.endAt], [at(1), at(29.5)]);
  assert.deepEqual([t2.startAt, t2.endAt], [at(160), at(215)]);
  assert.deepEqual(result.unattached.map((e) => e.id), [2, 3]);
});

test("calibration adopts a measured capacity after three readings within 10 %", () => {
  // 50 km window: 30 % SoC used, 6 % fuel used.
  const snapshots = [snap(0, 1000, 90, 50, false), snap(30, 1025, 75, 47, false), snap(60, 1050, 60, 44, false)];
  let state = { batteryKwh: 18.3, tankLitres: 60, batterySource: "model", tankSource: "model" };
  const readings = [
    { last50km: { evKwh: 5.4, petrolLitres: 3.6 }, updatedAt: at(61) }, // 18.0 kWh, 60 L
    { last50km: { evKwh: 5.7, petrolLitres: 3.9 }, updatedAt: at(62) }, // 19.0 kWh, 65 L
    { last50km: { evKwh: 5.4, petrolLitres: 3.6 }, updatedAt: at(62) }, // duplicate stamp: ignored
    { last50km: { evKwh: 5.55, petrolLitres: 3.0 }, updatedAt: at(63) }, // 18.5 kWh, 50 L
  ];
  for (const energy of readings) state = calibrate(snapshots, energy, state);
  assert.deepEqual(state.batteryReadings, [18, 19, 18.5]);
  assert.equal(state.batteryKwh, 18.5);
  assert.equal(state.batterySource, "measured");
  // 60, 65, 50 L spread more than 10 %: the tank stays on the model value.
  assert.deepEqual(state.tankReadings, [60, 65, 50]);
  assert.equal(state.tankLitres, 60);
  assert.equal(state.tankSource, "model");
  // A manual value is never overwritten.
  const manual = calibrate(snapshots, { last50km: { evKwh: 5.4 }, updatedAt: at(99) }, { ...state, batterySource: "manual", batteryKwh: 20 });
  assert.equal(manual.batteryKwh, 20);
  assert.equal(manual.batterySource, "manual");
});

test("migrations are idempotent", () => {
  const sql = memorySql();
  assert.equal(migrate(sql), 3);
  assert.equal(migrate(sql), 3);
  const tables = sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name`).toArray().map((r) => r.name);
  for (const name of ["snapshots", "trips", "phone_events", "phones", "settings", "leases", "schema_version"]) {
    assert.ok(tables.includes(name), name);
  }
});

test("lease: granted to the first phone, renewed by the holder, refused to another phone until it expires", () => {
  let now = new Date(T0);
  const store = new TripStore(memorySql(), { now: () => now });
  const first = store.lease({ phoneId: "A", phoneName: "Hieu's iPhone", kind: "car", ttlSeconds: 120 });
  assert.equal(first.granted, true);
  assert.equal(first.leader.phoneId, "A");
  assert.equal(first.leader.name, "Hieu's iPhone");
  const refused = store.lease({ phoneId: "B", phoneName: "Other", kind: "car", ttlSeconds: 120 });
  assert.equal(refused.granted, false);
  assert.equal(refused.leader.phoneId, "A");
  now = new Date(T0 + 100000);
  const renewed = store.lease({ phoneId: "A", kind: "car", ttlSeconds: 120 });
  assert.equal(renewed.granted, true);
  assert.equal(renewed.leader.until, new Date(T0 + 220000).toISOString());
  now = new Date(T0 + 221000);
  assert.equal(store.getPhones().leader, null);
  const taken = store.lease({ phoneId: "B", phoneName: "Other", kind: "car", ttlSeconds: 60 });
  assert.equal(taken.granted, true);
  assert.equal(taken.leader.phoneId, "B");
  assert.deepEqual(store.getPhones().phones.map((p) => p.id), ["B", "A"]);
});

test("sync pulls snapshots and prices, seeds capacity, derives and prices trips, attaches events", async () => {
  let now = new Date(T0 + 3600000);
  const store = new TripStore(memorySql(), { now: () => now });
  store.putSettings({ priceKwh: 3700 });
  const calls = [];
  const container = {
    "/snapshots": { snapshots: [snap(0, 1000, 80, 50, true), snap(30, 1020, 60, 50, false)], serverStartedAt: at(-100) },
    "/prices": {
      petrol: { product: "E10 RON 95-III", zone: 1, vndPerLitre: 23230, source: "webgia", cycle: "2026-10-30", fetchedAt: at(0), stale: false },
      capacityHint: { model: "BYD SEALION 6", batteryKwh: 18.3, tankLitres: 60 },
    },
    "/energy": null,
  };
  const fetchJson = async (path) => {
    calls.push(path);
    return container[path.split("?")[0]] ?? null;
  };

  // The phone's arrival arrives before the cron has pulled the trip.
  const posted = store.postEvents({
    phoneId: "A",
    phoneName: "Hieu's iPhone",
    events: [
      { kind: "departure", at: at(-1), lat: 10.8, lon: 106.6 },
      { kind: "arrival", at: at(32), lat: 10.9, lon: 106.7 },
    ],
  });
  assert.equal(posted.attached, 0);

  const report = await store.sync(fetchJson);
  assert.deepEqual(report, { snapshots: 2, trips: 1, attached: 2, prices: true, energy: false });
  assert.ok(calls.includes("/snapshots"));
  assert.ok(calls.includes("/energy"));

  const settings = store.getSettings();
  assert.equal(settings.batteryKwh, 18.3);
  assert.equal(settings.tankLitres, 60);
  assert.equal(settings.batterySource, "model");

  const listed = store.listTrips();
  assert.equal(listed.trips.length, 1);
  const trip = listed.trips[0];
  assert.equal(trip.km, 20);
  assert.equal(trip.kwh, 3.66);
  assert.equal(trip.phoneId, "A");
  assert.equal(trip.phoneName, "Hieu's iPhone");
  assert.equal(trip.startAt, at(-1));
  assert.equal(trip.endAt, at(32));
  assert.deepEqual(trip.endLocation, { lat: 10.9, lon: 106.7 });
  assert.deepEqual(trip.flags, []);
  assert.equal(trip.cost.priceLitre, 23230);
  assert.equal(trip.cost.petrolCycle, "2026-10-30");
  assert.equal(listed.openTrip, null);
  assert.equal(listed.settings.evRate, 0.183);

  // Second sync asks only for newer snapshots and does not poll /energy again within the hour.
  calls.length = 0;
  container["/snapshots"] = { snapshots: [snap(60, 1020, 60, 50, true)] };
  now = new Date(now.getTime() + 300000);
  const again = await store.sync(fetchJson);
  assert.equal(again.trips, 0);
  assert.ok(calls.some((c) => c === `/snapshots?since=${encodeURIComponent(at(30))}`));
  assert.ok(!calls.includes("/energy"));
  assert.equal(store.listTrips().openTrip.odoStart, 1020);

  // Soft delete shows up only when the client asks with `since`.
  assert.equal(store.deleteTrip(trip.id), true);
  assert.equal(store.listTrips().trips.length, 0);
  const withSince = store.listTrips({ since: at(0) });
  assert.equal(withSince.trips.length, 1);
  assert.ok(withSince.trips[0].deletedAt);
});

test("upgrading from v1 re-cuts 5 Nov 2026: two drives, the second reported 36 minutes late", async () => {
  const utc = (h, m, s = 0) => new Date(Date.UTC(2026, 10, 5, h - 7, m, s)).toISOString(); // Vietnam time
  const car = (time, odometerKm, batteryPercent, fuelPercent, powerOn) => ({
    ...snap(0, odometerKm, batteryPercent, fuelPercent, powerOn),
    at: time,
    receivedAt: time,
  });
  const snapshots = [
    car(new Date(Date.UTC(2026, 10, 4, 15, 39, 15)).toISOString(), 3776, 27, 8, false),
    car(utc(16, 49, 34), 3778, 27, 7, true),
    car(utc(17, 4, 56), 3782, 30, 7, true),
    car(utc(17, 14, 51), 3784, 32, 6, false),
    car(utc(20, 40, 26), 3788, 34, 6, true),
    car(utc(20, 57, 14), 3790, 36, 5, false),
  ];
  const sql = memorySql();
  const now = () => new Date(utc(21, 30));
  const store = new TripStore(sql, { now });
  store.insertSnapshots(snapshots);
  store.postEvents({
    phoneId: "A",
    events: [
      { kind: "departure", at: utc(16, 48) },
      { kind: "departure", at: utc(17, 14, 23) },
      { kind: "arrival", at: utc(17, 14, 31) },
      { kind: "departure", at: utc(20, 4) },
      { kind: "arrival", at: utc(20, 49, 15) },
    ],
  });
  // A trip from the old cut, which the rebuild replaces.
  store.insertTrip(computeTrip({ id: "old", startAt: utc(17, 14, 51), endAt: utc(20, 40, 26), odoStart: 3784, odoEnd: 3788 }));

  // Back to v1, as the live store was before this change, then open it again.
  for (const column of ["car_start_at", "car_end_at", "gap_start_at", "refills"]) sql.exec(`ALTER TABLE trips DROP COLUMN ${column}`);
  sql.exec(`UPDATE schema_version SET version = 1`);
  const upgraded = new TripStore(sql, { now });
  const trips = upgraded.listTrips().trips.reverse();
  assert.deepEqual(
    trips.map((t) => [t.startAt, t.endAt, t.odoStart, t.odoEnd, t.phoneId, t.flags]),
    [
      [utc(16, 48), utc(17, 14, 31), 3776, 3784, "A", []],
      [utc(20, 4), utc(20, 49, 15), 3784, 3790, "A", []],
    ],
  );
  assert.ok(upgraded.listTrips({ since: utc(21, 0) }).trips.find((t) => t.id === "old").deletedAt);
});

test("settings: PUT merges, manual capacity edits set the source", () => {
  const store = new TripStore(memorySql());
  const s1 = store.putSettings({ priceKwh: 3700, notifyOnTrip: true });
  assert.equal(s1.priceKwh, 3700);
  assert.equal(s1.notifyOnTrip, true);
  assert.equal(s1.batterySource, "model");
  const s2 = store.putSettings({ batteryKwh: 20 });
  assert.equal(s2.priceKwh, 3700);
  assert.equal(s2.batteryKwh, 20);
  assert.equal(s2.batterySource, "manual");
  const s3 = store.putSettings({ petrolOverrideVndPerLitre: null, batterySource: "model" });
  assert.equal(s3.petrolOverrideVndPerLitre, null);
  assert.equal(s3.batterySource, "model");
});

test("HTTP handler answers the trip routes and leaves the rest to the container", async () => {
  const store = new TripStore(memorySql());
  const req = (path, init) => new Request(`http://container${path}`, init);
  assert.equal(await store.handle(req("/status")), null);
  assert.equal(await store.handle(req("/trips/sync", { method: "POST" })), null);
  const lease = await store.handle(
    req("/lease", { method: "POST", body: JSON.stringify({ phoneId: "A", phoneName: "P", kind: "car", ttlSeconds: 120 }) }),
  );
  assert.equal(lease.status, 200);
  assert.equal((await lease.json()).granted, true);
  const phones = await (await store.handle(req("/phones"))).json();
  assert.equal(phones.leader.phoneId, "A");
  const trips = await (await store.handle(req("/trips?limit=5"))).json();
  assert.deepEqual(trips.trips, []);
  assert.ok(trips.serverTime);
  const missing = await store.handle(req("/trips/nope", { method: "DELETE" }));
  assert.equal(missing.status, 404);
  const bad = await store.handle(req("/settings", { method: "PUT", body: "{" }));
  assert.equal(bad.status, 400);
});

test("refill edits: stored per kind, cleared back to the estimate, and resent to phones", async () => {
  let now = new Date(T0);
  const store = new TripStore(memorySql(), { now: () => now });
  store.run(
    `INSERT INTO trips (id, start_at, end_at, odo_start, odo_end, kwh, litres, fuel_start, fuel_end, flags, created_at)
     VALUES ('t', ?, ?, 0, 9, 1.3, 0, 5, 61, '["refuelledDuringTrip"]', ?)`,
    at(0), at(50), at(50),
  );
  assert.equal(store.listTrips().trips[0].refills, null);
  const lastPull = store.listTrips().serverTime;

  now = new Date(T0 + 3600000);
  const put = (id, body) =>
    store.handle(new Request(`http://container/trips/${id}/refill`, { method: "PUT", body: JSON.stringify(body) }));
  const edited = await (await put("t", { kind: "fuel", amount: 33.2, cost: 705000 })).json();
  assert.deepEqual(edited.refills, { fuel: { amount: 33.2, cost: 705000 } });
  await put("t", { kind: "charge", amount: null, cost: 40000 });
  assert.deepEqual(store.listTrips().trips[0].refills, {
    fuel: { amount: 33.2, cost: 705000 },
    charge: { amount: null, cost: 40000 },
  });
  assert.equal(store.listTrips({ since: lastPull }).trips.length, 1);

  await put("t", { kind: "charge" });
  await put("t", { kind: "fuel", amount: null, cost: null });
  assert.equal(store.listTrips().trips[0].refills, null);

  assert.equal((await put("nope", { kind: "fuel", amount: 1 })).status, 404);
  assert.equal((await put("t", { kind: "petrol", amount: 1 })).status, 400);
  assert.equal((await put("t", { kind: "fuel", amount: -1 })).status, 400);
});
