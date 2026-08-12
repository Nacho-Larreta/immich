package app.alextran.immich.connectivity

import org.junit.Assert.assertFalse
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
}

private class FakeNetworkMonitor(
  private var value: ConnectivityNetworkValue = ConnectivityNetworkValue(available = false),
) : ConnectivityNetworkMonitoring {
  private var onChanged: (() -> Unit)? = null

  override fun readCurrent(): ConnectivityNetworkValue = value

  override fun start(onChanged: () -> Unit) {
    this.onChanged = onChanged
  }

  override fun stop() {
    onChanged = null
  }
}
