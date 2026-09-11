import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import test from 'node:test'
import vm from 'node:vm'

// Exercise the actual touch handlers with native selection and scrolling mocked.
const source = readFileSync(new URL('../src/paginator.js', import.meta.url), 'utf8')
const handlers = source.slice(source.indexOf('  #onScroll() {'),
    source.indexOf('  // allows one to process rects'))
function fixture() {
    let selected = ''
    const frames = []
    const context = vm.createContext({
        window: { getSelection: () => selected },
        visualViewport: { scale: 1 },
        CustomEvent: class { constructor(type) { this.type = type } },
        requestAnimationFrame: fn => frames.push(fn),
    })
    const paginator = vm.runInContext(`new (class {
        #touchState; #touchScrolled; #pendingRelocate;
        #ignoreNativeScroll = false; #paginatedOffset = 100;
        #justAnchored = false; #pendingScrollFrame;
        #container = { scrollLeft: 100 };
        scrollProp = 'scrollLeft'; page = 1; scrolled = false; snaps = 0; events = [];
        dispatchEvent(e) { this.events.push(e.type); }
        snap() { this.snaps++; }
        #afterScroll() { this.events.push('relocate'); }
        #handleScrollBoundaries() {}
        nativeScroll(offset) { this.#container.scrollLeft = offset; this.#onScroll(); }
        get offset() { return this.#container.scrollLeft; }
        navigated(offset) { this.#paginatedOffset = offset; this.#container.scrollLeft = offset; }
        set navigating(value) { this.#ignoreNativeScroll = value; }
        start(e) { this.#onTouchStart(e); }
        move(e) { this.#onTouchMove(e); }
        end(e) { this.#onTouchEnd(e); }
        ${handlers}
    })()`, context)
    const event = x => ({ changedTouches: [{ screenX: x, screenY: 20 }],
        touches: [{ screenX: x, screenY: 20 }], timeStamp: 10,
        preventDefault() {} })
    return { paginator, event, select: text => { selected = text },
        flush: () => frames.splice(0).forEach(fn => fn()) }
}

test('handle drag remains selection-owned when native range temporarily disappears', () => {
    const f = fixture()
    f.select('never')
    f.paginator.start(f.event(90))
    f.select('')
    f.paginator.move(f.event(20))
    f.paginator.end(f.event(20))
    f.flush()
    assert.equal(f.paginator.snaps, 0)
    assert.equal(f.paginator.events.includes('doctouchmove'), false)
    assert.equal(f.paginator.events.includes('doctouchend'), false)
})

test('selection established after touchstart also suppresses page snap', () => {
    const f = fixture()
    f.paginator.start(f.event(90))
    f.select('never')
    f.paginator.move(f.event(70))
    f.select('')
    f.paginator.end(f.event(20))
    f.flush()
    assert.equal(f.paginator.snaps, 0)
    assert.equal(f.paginator.events.includes('doctouchmove'), false)
    assert.equal(f.paginator.events.includes('doctouchend'), false)
})

test('ordinary page swipe still snaps', () => {
    const f = fixture()
    f.paginator.start(f.event(90))
    f.paginator.move(f.event(20))
    f.paginator.end(f.event(20))
    f.flush()
    assert.equal(f.paginator.snaps, 1)
})

test('selection appearing at release suppresses reader gestures and snapping', () => {
    const f = fixture()
    f.paginator.start(f.event(90))
    f.select('never')
    f.paginator.end(f.event(20))
    f.flush()
    assert.equal(f.paginator.snaps, 0)
    assert.equal(f.paginator.events.includes('doctouchend'), false)
})

test('native handle scrolling stays on the current explicit page across a page advance', () => {
    const f = fixture()
    f.select('text across two pages')
    f.paginator.nativeScroll(145)
    assert.equal(f.paginator.offset, 100)
    f.paginator.navigating = true
    f.paginator.nativeScroll(160)
    assert.equal(f.paginator.offset, 160)
    f.paginator.navigated(200)
    f.paginator.navigating = false
    f.paginator.nativeScroll(175)
    assert.equal(f.paginator.offset, 200)
    f.flush()
    assert.equal(f.paginator.events.includes('relocate'), false)
    f.select('')
    f.paginator.nativeScroll(240)
    f.flush()
    assert.equal(f.paginator.offset, 240)
    assert.equal(f.paginator.events.includes('relocate'), true)
})

test('handle-owned gesture holds page even during a transient empty range', () => {
    const f = fixture()
    f.select('never')
    f.paginator.start(f.event(90))
    f.select('')
    f.paginator.nativeScroll(80)
    assert.equal(f.paginator.offset, 100)
})
