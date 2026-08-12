package app.alextran.immich.connectivity

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConnectivityApiImplTest {
  @Test
  fun recreatedApiUsesNewerProcessWideEpoch() {
    val first = ConnectivityApiImpl(FakeNetworkMonitor(), {})
    first.start()
    val firstSnapshot = first.readCurrentSnapshot()

    val recreated = ConnectivityApiImpl(FakeNetworkMonitor(), {})
    recreated.start()
    val recreatedSnapshot = recreated.readCurrentSnapshot()

    assertTrue(recreatedSnapshot.monitorEpoch > firstSnapshot.monitorEpoch)
  }

  @Test
  fun vpnOverCellularIsNotReportedAsWifi() {
    val monitor = FakeNetworkMonitor(
      ConnectivityNetworkValue(available = true, usesCellular = true, usesVpn = true),
    )
    val api = ConnectivityApiImpl(monitor, {})
    api.start()

    val capabilities = api.readCurrentSnapshot().capabilities

    assertTrue(capabilities.contains(ConnectivityNetworkCapability.CELLULAR))
    assertTrue(capabilities.contains(ConnectivityNetworkCapability.VPN))
    assertFalse(capabilities.contains(ConnectivityNetworkCapability.WIFI))
  }

  @Test
  fun readBeforeCallbackAdvancesRevisionAndMatchingCallbackDoesNotAdvanceAgain() {
    val monitor = FakeNetworkMonitor()
    val published = mutableListOf<ConnectivityTransportSnapshot>()
    val api = ConnectivityApiImpl(monitor, published::add)
    api.start()
    val initial = api.readCurrentSnapshot()
    monitor.value = ConnectivityNetworkValue(available = true, usesWifi = true)

    val read = api.readCurrentSnapshot()
    monitor.emitChange()
    val afterCallback = api.readCurrentSnapshot()

    assertTrue(read.revision > initial.revision)
    assertEquals(read.revision, afterCallback.revision)
    assertEquals(1, published.size)
  }
}

private class FakeNetworkMonitor(
  var value: ConnectivityNetworkValue = ConnectivityNetworkValue(available = false),
) : ConnectivityNetworkMonitoring {
  private var onChanged: (() -> Unit)? = null

  override fun readCurrent(): ConnectivityNetworkValue = value

  override fun start(onChanged: () -> Unit) {
    this.onChanged = onChanged
  }

  override fun stop() {
    onChanged = null
  }

  fun emitChange() {
    onChanged?.invoke()
  }
}
