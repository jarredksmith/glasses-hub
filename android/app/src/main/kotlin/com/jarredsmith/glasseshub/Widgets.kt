package com.jarredsmith.glasseshub

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp

// The building blocks every settings page is made of: a titled group of rows, and the kinds of row.

@Composable
fun Group(title: String? = null, footer: String? = null, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        if (title != null) Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 12.dp, bottom = 6.dp))
        Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceContainer, modifier = Modifier.fillMaxWidth()) {
            Column(Modifier.padding(vertical = 4.dp), content = content)
        }
        if (footer != null) Text(footer, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 12.dp, end = 12.dp, top = 6.dp))
    }
}

@Composable
private fun RowBox(onClick: (() -> Unit)? = null, content: @Composable () -> Unit) {
    Box(Modifier.fillMaxWidth().heightIn(min = 48.dp).let { if (onClick != null) it.clickable(onClick = onClick) else it }.padding(horizontal = 16.dp, vertical = 6.dp), contentAlignment = Alignment.CenterStart) { content() }
}

@Composable
fun Toggle(label: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) = RowBox({ if (enabled) onChange(!checked) }) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), color = if (enabled) Color.Unspecified else MaterialTheme.colorScheme.onSurfaceVariant)
        Switch(checked, onChange, enabled = enabled)
    }
}

@Composable
fun Check(label: String, checked: Boolean, onChange: (Boolean) -> Unit) = RowBox({ onChange(!checked) }) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Checkbox(checked, onChange)
    }
}

/** A row that opens a list to pick one of. */
@Composable
fun <T> Choice(label: String, options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    RowBox({ open = true }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, Modifier.weight(1f))
            Box {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(options.firstOrNull { it.first == selected }?.second ?: "", color = MaterialTheme.colorScheme.primary)
                    Icon(Icons.Filled.ArrowDropDown, null, tint = MaterialTheme.colorScheme.primary)
                }
                DropdownMenu(open, { open = false }) {
                    for ((value, name) in options) DropdownMenuItem({ Text(name) }, { open = false; onSelect(value) })
                }
            }
        }
    }
}

val actionNames = listOf(0 to "Next", 3 to "Previous", 1 to "Select", 2 to "Apps menu", 5 to "Dashboard", 4 to "Nothing")
/** Chooses what a button or gesture does. */
@Composable
fun ActionChoice(label: String, selected: Int, onSelect: (Int) -> Unit) = Choice(label, actionNames, selected, onSelect)

@Composable
fun Stepper(label: String, value: Int, range: IntRange, step: Int = 1, onChange: (Int) -> Unit) = RowBox {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        FilledTonalIconButton({ onChange((value - step).coerceIn(range.first, range.last)) }, enabled = value > range.first) { Icon(Icons.Filled.Remove, "Less") }
        Spacer(Modifier.width(8.dp))
        FilledTonalIconButton({ onChange((value + step).coerceIn(range.first, range.last)) }, enabled = value < range.last) { Icon(Icons.Filled.Add, "More") }
    }
}

@Composable
fun Field(label: String, value: String, secret: Boolean = false, lines: Int = 1, capitals: Boolean = false, number: Boolean = false, onChange: (String) -> Unit) {
    OutlinedTextField(value, onChange, label = { Text(label) }, singleLine = lines == 1, minLines = lines, maxLines = if (lines == 1) 1 else 12,
        visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
        keyboardOptions = KeyboardOptions(capitalization = if (capitals) KeyboardCapitalization.Characters else KeyboardCapitalization.None,
            keyboardType = if (secret) KeyboardType.Password else if (number) KeyboardType.Number else KeyboardType.Text, autoCorrectEnabled = !secret && !capitals),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp))
}

@Composable
fun Action(label: String, enabled: Boolean = true, danger: Boolean = false, onClick: () -> Unit) = RowBox(if (enabled) onClick else null) {
    Text(label, color = if (!enabled) MaterialTheme.colorScheme.onSurfaceVariant else if (danger) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Medium)
}

@Composable
fun Info(label: String, value: String) = RowBox {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, Modifier.weight(1f))
        Text(value, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun Note(text: String) { if (text.isNotEmpty()) RowBox { Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant) } }

@Composable
fun Go(label: String, detail: String = "", onClick: () -> Unit) = RowBox(onClick) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(label)
            if (detail.isNotEmpty()) Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 2)
        }
        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
fun Line() = HorizontalDivider(Modifier.padding(start = 16.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))

@Composable
fun Buttons(vararg items: Pair<String, () -> Unit>) = Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
    for ((label, onClick) in items) TextButton(onClick) { Text(label) }
}
