const assert = require('node:assert/strict')
const path = require('node:path')
const { app, xlang } = require('electron/main')

function requiredPath(name) {
  const value = process.env[name]
  if (!value) {
    throw new Error(`${name} is required`)
  }
  return path.resolve(value)
}

async function run() {
  const runtimeDirectory = requiredPath('XLANG_RUNTIME_DIR')
  const bridgePath = requiredPath('XLANG_BRIDGE_PATH')
  const testModulePath = requiredPath('XLANG_TEST_MODULE')
  let testModule

  try {
    await xlang.initialize({
      libraryPath: bridgePath,
      appPath: runtimeDirectory,
      librarySearchPaths: [path.dirname(testModulePath)]
    })
    testModule = await xlang.importModule('bridge_event_test', {
      fromPath: testModulePath
    })

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
