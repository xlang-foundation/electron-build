const assert = require('node:assert/strict')
const path = require('node:path')
const { app, xlang } = require('electron/main')

app.disableHardwareAcceleration()

function requiredPath(name) {
  const value = process.env[name]
  if (!value) {
    throw new Error(`${name} is required`)
  }
  return path.resolve(value)
}

function optionalPath(name) {
  const value = process.env[name]
  return value ? path.resolve(value) : undefined
}

async function run() {
  assert.equal(typeof xlang.initialize, 'function')
  assert.equal(typeof xlang.importModule, 'function')
  assert.equal(typeof xlang.shutdown, 'function')

  const runtimeDirectory = optionalPath('XLANG_RUNTIME_DIR')
  const bridgePath = optionalPath('XLANG_BRIDGE_PATH')
  const testModulePath = requiredPath('XLANG_TEST_MODULE')
  if ((runtimeDirectory === undefined) !== (bridgePath === undefined)) {
    throw new Error(
      'XLANG_RUNTIME_DIR and XLANG_BRIDGE_PATH must either both be set or both be omitted'
    )
  }
  let testModule

  try {
    const initializeOptions = {
      librarySearchPaths: [path.dirname(testModulePath)]
    }
    if (runtimeDirectory && bridgePath) {
      initializeOptions.libraryPath = bridgePath
      initializeOptions.appPath = runtimeDirectory
    }
    await xlang.initialize(initializeOptions)
    testModule = await xlang.importModule('bridge_event_test', {
      fromPath: testModulePath
    })

    const queuedWait = testModule.call('wait_until_blocked', [500])
    await new Promise((resolve) => setTimeout(resolve, 25))
    const directStartedAt = performance.now()
    assert.equal(testModule.callSync('echo', ['direct-call']), 'direct-call')
    const directElapsed = performance.now() - directStartedAt
    assert.ok(
      directElapsed < 150,
      `callSync waited behind the asynchronous worker queue (${directElapsed.toFixed(1)}ms)`
    )
    assert.equal(await queuedWait, false)

    let eventCount = 0
    let listener
    const received = new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error('Timed out waiting for the XLang changed event')),
        5000
      )
      listener = (event) => {
        try {
          eventCount += 1
          assert.deepEqual(event.args, [17, 'bridge-event'])
          assert.deepEqual(event.kwargs, { source: 'native-test-module' })
          clearTimeout(timer)
          resolve()
        } catch (error) {
          clearTimeout(timer)
          reject(error)
        }
      }
    })

    await testModule.on('changed', listener)
    assert.equal(await testModule.emit(17, 'bridge-event'), true)
    await received
    await testModule.off('changed', listener)

    assert.equal(await testModule.emit(18, 'after-off'), true)
    await new Promise((resolve) => setTimeout(resolve, 250))
    assert.equal(eventCount, 1)

    await testModule.dispose()
    testModule = undefined
  } finally {
    if (testModule) {
      await testModule.dispose().catch(() => {})
    }
    await xlang.shutdown().catch(() => {})
  }
}

app.whenReady()
  .then(run)
  .then(() => {
    console.log('Electron XLang smoke test passed')
    app.exit(0)
  })
  .catch((error) => {
    console.error(error)
    app.exit(1)
  })
