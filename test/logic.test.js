const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const src = fs.readFileSync(path.join(__dirname, "..", "Logic.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const L = {}
vm.createContext(L)
vm.runInContext(src, L)

let failed = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) { failed++; console.log("FAIL " + name + "\n     " + e.message) }
}

const cfgText = JSON.stringify({
  router: "http://192.168.88.1",
  dhcpServer: "dhcp-lan",
  lanes: [
    { id: "new", name: "New", from: "192.168.88.2", to: "192.168.88.31", pool: true },
    { id: "smart", name: "Lights & smart", from: "192.168.88.32", to: "192.168.88.127" },
    { id: "mine", name: "Mine", from: "192.168.88.200", to: "192.168.88.250" }
  ],
  notes: { "00:11:22:33:44:03": "Frigate camera" }
})
const cfg = L.parseConfig(cfgText)

const leases = [
  { ".id": "*1", address: "192.168.88.32", "active-address": "192.168.88.32", "mac-address": "00:11:22:33:44:01", comment: "Hue bridge", dynamic: "false", status: "bound", server: "dhcp-lan", "host-name": "hue-bridge" },
  { ".id": "*2", address: "192.168.88.31", "active-address": "192.168.88.31", "mac-address": "00:11:22:33:44:02", dynamic: "true", status: "bound", server: "dhcp-lan", "host-name": "Phone" },
  { ".id": "*3", address: "192.168.88.48", "mac-address": "00:11:22:33:44:03", comment: "Tapo cam", dynamic: "false", status: "waiting", server: "dhcp-lan" },
  { ".id": "*4", address: "10.99.0.11", "mac-address": "00:11:22:33:44:04", dynamic: "true", status: "bound", server: "dhcp-us" },
  { ".id": "*5", address: "192.168.88.33", "active-address": "192.168.88.5", "mac-address": "00:11:22:33:44:05", comment: "Nanoleaf", dynamic: "false", status: "bound", server: "dhcp-lan" },
  { ".id": "*6", address: "192.168.88.200", "mac-address": "00:11:22:33:44:06", comment: "<img src=x>\u0007PC", dynamic: "false", status: "bound", server: "dhcp-lan" }
]
const regs = [{ ".id": "*9", interface: "cap-wifi2", "mac-address": "00:11:22:33:44:02", band: "2ghz-n", signal: "-60", ssid: "home" }]
const radios = [{ name: "cap-wifi2", cap: "ap2@00:11:22:33:44:99%*9", "configuration.ssid": "home" }]
const arps = [{ "mac-address": "00:11:22:33:44:01", status: "reachable" }]
const devices = L.buildDevices({ leases, regs, arps, radios, identity: "router" }, cfg)
const byMac = m => devices.find(d => d.mac === m)

test("config parses lanes and lowercases nothing important", () => {
  assert.strictEqual(cfg.error, undefined)
  assert.strictEqual(cfg.lanes.length, 3)
  assert.strictEqual(cfg.notes["00:11:22:33:44:03"], "Frigate camera")
})

test("config rejects bad router and overlapping garbage", () => {
  assert.ok(L.parseConfig('{"router":"http://x; rm -rf /","lanes":[]}').error)
  assert.ok(L.parseConfig("not json").error)
  assert.ok(L.parseConfig('{"router":"http://192.168.88.1","lanes":[{"id":"a","from":"10.0.0.9","to":"10.0.0.1"}]}').error)
})

test("other dhcp servers are ignored", () => {
  assert.strictEqual(byMac("00:11:22:33:44:04"), undefined)
})

test("lanes come from the configured address", () => {
  assert.strictEqual(byMac("00:11:22:33:44:01").lane, "smart")
  assert.strictEqual(byMac("00:11:22:33:44:02").lane, "new")
  assert.strictEqual(byMac("00:11:22:33:44:06").lane, "mine")
})

test("wifi info resolves the CAP name and band", () => {
  const d = byMac("00:11:22:33:44:02")
  assert.strictEqual(d.wifi.ap, "ap2")
  assert.strictEqual(d.wifi.band, "2.4 GHz")
  assert.strictEqual(d.online, true)
  assert.strictEqual(d.name, "Phone")
  assert.strictEqual(d.isStatic, false)
})

test("pending when the device still holds another address", () => {
  assert.strictEqual(byMac("00:11:22:33:44:05").pending, true)
  assert.strictEqual(byMac("00:11:22:33:44:01").pending, false)
})

test("names are cleaned of control chars but markup stays text", () => {
  const d = byMac("00:11:22:33:44:06")
  assert.strictEqual(d.name, "<img src=x> PC")
  assert.ok(L.cleanName("x".repeat(200)).length <= 48)
})

test("next free ip skips used and active addresses", () => {
  assert.strictEqual(L.nextFreeIp("smart", devices, cfg, ""), "192.168.88.34")
  assert.strictEqual(L.nextFreeIp("new", devices, cfg, ""), "192.168.88.2")
})

test("next free ip ignores the device being moved", () => {
  assert.strictEqual(L.nextFreeIp("smart", devices, cfg, "00:11:22:33:44:01"), "192.168.88.32")
})

test("validateAssign catches range and collisions", () => {
  assert.ok(L.validateAssign("192.168.88.150", "smart", "X", devices, cfg).indexOf("Outside") === 0)
  assert.ok(L.validateAssign("192.168.88.32", "smart", "00:11:22:33:44:02", devices, cfg).indexOf("taken") > 0)
  assert.strictEqual(L.validateAssign("192.168.88.40", "smart", "00:11:22:33:44:02", devices, cfg), "")
  assert.ok(L.validateAssign("192.168.88.1; reboot", "smart", "X", devices, cfg))
})

test("router address is never handed out", () => {
  const c2 = L.parseConfig(JSON.stringify({ router: "http://192.168.88.1", lanes: [{ id: "a", from: "192.168.88.1", to: "192.168.88.3" }] }))
  assert.strictEqual(L.nextFreeIp("a", [], c2, ""), "192.168.88.2")
})

test("unsorted are the dynamic leases", () => {
  assert.strictEqual(JSON.stringify(L.unsorted(devices).map(d => d.mac)), JSON.stringify(["00:11:22:33:44:02"]))
})

test("rates parse and format", () => {
  assert.strictEqual(L.parseRate("352bps"), 352)
  assert.strictEqual(L.parseRate("1.5Mbps"), 1500000)
  assert.strictEqual(L.parseRate("garbage"), 0)
  assert.strictEqual(L.formatRate(1500000), "1.5 Mb/s")
})

test("bedtime crosses midnight and round-trips", () => {
  assert.strictEqual(L.bedtimeWindow("22:00", "07:00").window, "7h-22h")
  assert.strictEqual(L.bedtimeWindow("23:30", "06:15").window, "6h15m-23h30m")
  assert.ok(L.bedtimeWindow("07:00", "22:00").error)
  assert.ok(L.bedtimeWindow("25:00", "07:00").error)
  const b = L.windowToBedtime("6h15m-23h30m")
  assert.strictEqual(b.from, "23:30"); assert.strictEqual(b.to, "06:15")
  assert.strictEqual(L.windowToBedtime("0s-1d"), null)
})

test("lookups pair queries with their question, newest first, deduped", () => {
  const rows = [
    { time: "2026-11-10 02:00:01", message: "--- got query from 192.168.88.31:1000:" },
    { time: "2026-11-10 02:00:01", message: "question: a.example.com.:A:IN" },
    { time: "2026-11-10 02:00:01", message: "question: a.example.com.:A:IN" },
    { time: "2026-11-10 02:00:02", message: "--- got query from 192.168.88.40:1000:" },
    { time: "2026-11-10 02:00:02", message: "question: google.com.:A:IN" },
    { time: "2026-11-10 02:00:03", message: "--- got query from 192.168.88.31:1001:" },
    { time: "2026-11-10 02:00:03", message: "question: b.example.com.:UNKNOWN (65):IN" },
    { time: "2026-11-10 02:00:04", message: "--- got query from 192.168.88.31:1002:" },
    { time: "2026-11-10 02:00:04", message: "question: a.example.com.:AAAA:IN" }
  ]
  const r = L.parseLookups(rows, "192.168.88.31", 10)
  assert.strictEqual(JSON.stringify(r.map(x => x.name)), JSON.stringify(["a.example.com", "b.example.com"]))
  assert.strictEqual(r[0].time, "02:00:04")
})

test("presence waits before calling someone gone", () => {
  let s = L.presenceStep(null, true, 0, 600000).state
  let r = L.presenceStep(s, false, 300000, 600000)
  assert.strictEqual(r.event, "")
  r = L.presenceStep(r.state, false, 700000, 600000)
  assert.strictEqual(r.event, "left")
  r = L.presenceStep(r.state, true, 800000, 600000)
  assert.strictEqual(r.event, "arrived")
})

test("kid-control state lands on devices", () => {
  const devs = L.buildDevices({ leases, regs, arps, radios, identity: "x" }, cfg)
  L.attachKids(devs,
    [{ ".id": "*1", name: "omarchy-all", paused: "false", mon: "0s-1d" },
     { ".id": "*2", name: L.kidName("00:11:22:33:44:02"), paused: "true", mon: "7h-22h", tue: "7h-22h", wed: "7h-22h", thu: "7h-22h", fri: "7h-22h", sat: "7h-22h", sun: "7h-22h" }],
    [{ ".id": "*a", "mac-address": "00:11:22:33:44:02", user: L.kidName("00:11:22:33:44:02"), "rate-down": "2.0Mbps", "rate-up": "100kbps" },
     { ".id": "*b", "mac-address": "00:11:22:33:44:01", user: "omarchy-all", "rate-down": "0bps" }])
  const mara = devs.find(d => d.mac === "00:11:22:33:44:02")
  assert.strictEqual(mara.paused, true)
  assert.strictEqual(mara.bedtime.from, "22:00")
  assert.strictEqual(mara.rateDown, 2000000)
  const hue = devs.find(d => d.mac === "00:11:22:33:44:01")
  assert.strictEqual(hue.kidId, "")
  assert.strictEqual(hue.paused, false)
})

test("guesses a Xiaomi phone from its model code and DHCP class", () => {
  const g = L.guessDevice({ hostName: "M2101K6G", classId: "android-dhcp-13", randomMac: true }, "")
  assert.ok(g.label.indexOf("Redmi Note 10 Pro") !== -1)
  assert.ok(g.label.indexOf("Android 13") !== -1)
  assert.strictEqual(L.isRandomMac("6A:00:00:00:00:01"), true)
  assert.strictEqual(L.isRandomMac("00:11:22:33:44:01"), false)
  assert.strictEqual(L.guessFromLookups([{ name: "api.miui.com" }, { name: "x.xiaomi.net" }, { name: "apple.com" }]), "Xiaomi / Apple")
})

console.log(failed ? `\n${failed} failed` : "\nall passed")
process.exit(failed ? 1 : 0)
