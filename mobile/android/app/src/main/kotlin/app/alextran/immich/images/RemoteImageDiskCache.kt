package app.alextran.immich.images

import app.alextran.immich.core.RemoteImageCacheScope
import java.io.File
import java.io.IOException
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest

internal class RemoteImageDiskCache(
  private val directory: File,
  private val maxEntryBytes: Long = DEFAULT_MAX_ENTRY_BYTES,
  private val maxTotalBytes: Long = DEFAULT_MAX_TOTAL_BYTES,
  private val maxEntries: Int = DEFAULT_MAX_ENTRIES,
) {
  private var accessClock = System.currentTimeMillis()

  init {
    require(maxEntryBytes > 0) { "Cache entry limit must be positive" }
    require(maxTotalBytes >= maxEntryBytes) { "Total cache limit must fit one entry" }
    require(maxEntries > 0) { "Cache entry count must be positive" }
  }

  @Synchronized
  fun read(
    scope: RemoteImageCacheScope,
    url: String,
  ): ByteArray? {
    val entry = entryFor(scope, url)
    if (!entry.isFile || entry.length() !in 1..maxEntryBytes) return null
    return runCatching { entry.readBytes().also { touch(entry) } }.getOrNull()
  }

  @Synchronized
  @Throws(IOException::class)
  fun write(
    scope: RemoteImageCacheScope,
    url: String,
    bytes: ByteArray,
  ) {
    if (bytes.isEmpty() || bytes.size.toLong() > maxEntryBytes) return
    if (!directory.exists() && !directory.mkdirs()) {
      throw IOException("Unable to create remote image cache")
    }
    if (!directory.isDirectory) throw IOException("Remote image cache path is not a directory")

    val scopeDirectory = File(directory, scope.directoryName)
    if (!scopeDirectory.exists() && !scopeDirectory.mkdirs()) throw IOException("Unable to create cache scope")
    val entry = entryFor(scope, url)
    val pending = File.createTempFile(".${entry.name}.", ".pending", scopeDirectory)
    try {
      pending.outputStream().use { output ->
        output.write(bytes)
        output.fd.sync()
      }
      publish(pending, entry)
      touch(entry)
      trim()
    } finally {
      pending.delete()
    }
  }

  @Synchronized
  @Throws(IOException::class)
  fun clear(): Long {
    if (!directory.exists()) return 0
    if (!directory.isDirectory) throw IOException("Remote image cache path is not a directory")
    val clearedBytes = cacheEntries().sumOf(File::length)
    directory.listFiles()?.forEach(::deleteTree)
    return clearedBytes
  }

  @Synchronized
  fun retainOnly(scope: RemoteImageCacheScope?) {
    if (!directory.exists()) return
    directory.listFiles()?.forEach { child ->
      if (scope == null || child.name != scope.directoryName) deleteTree(child)
    }
  }

  private fun entryFor(
    scope: RemoteImageCacheScope,
    url: String,
  ): File {
    require(url.isNotEmpty()) { "Remote image URL must not be empty" }
    val digest = MessageDigest.getInstance("SHA-256").digest(url.toByteArray(Charsets.UTF_8))
    return File(
      File(directory, scope.directoryName),
      digest.joinToString(separator = "") { byte -> (byte.toInt() and 0xff).toString(16).padStart(2, '0') },
    )
  }

  private fun trim() {
    val entries = cacheEntries().sortedWith(compareBy(File::lastModified, File::getName)).toMutableList()
    var totalBytes = entries.sumOf(File::length)
    while (entries.size > maxEntries || totalBytes > maxTotalBytes) {
      val victim = entries.removeFirst()
      totalBytes -= victim.length()
      if (!victim.delete()) throw IOException("Unable to evict remote image cache entry")
    }
    directory
      .listFiles()
      ?.filter(File::isDirectory)
      ?.filter { it.list()?.isEmpty() == true }
      ?.forEach(File::delete)
  }

  private fun cacheEntries(): List<File> =
    if (!directory.exists()) {
      emptyList()
    } else {
      directory
        .walkTopDown()
        .filter(File::isFile)
        .toList()
    }

  private fun touch(entry: File) {
    accessClock = maxOf(accessClock + 1, System.currentTimeMillis())
    entry.setLastModified(accessClock)
  }

  private fun deleteTree(entry: File) {
    if (!entry.deleteRecursively()) throw IOException("Unable to purge remote image cache scope")
  }

  private fun publish(
    pending: File,
    entry: File,
  ) {
    try {
      Files.move(
        pending.toPath(),
        entry.toPath(),
        StandardCopyOption.ATOMIC_MOVE,
        StandardCopyOption.REPLACE_EXISTING,
      )
    } catch (_: AtomicMoveNotSupportedException) {
      Files.move(pending.toPath(), entry.toPath(), StandardCopyOption.REPLACE_EXISTING)
    }
  }

  private companion object {
    const val DEFAULT_MAX_ENTRY_BYTES = 100L * 1024 * 1024
    const val DEFAULT_MAX_TOTAL_BYTES = 512L * 1024 * 1024
    const val DEFAULT_MAX_ENTRIES = 2048
  }
}
