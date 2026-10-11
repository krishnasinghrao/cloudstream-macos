package com.lagradost.cloudstream3.utils

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

val workerDispatcher: CoroutineDispatcher = Dispatchers.IO
internal typealias WorkerThread = androidx.annotation.WorkerThread
