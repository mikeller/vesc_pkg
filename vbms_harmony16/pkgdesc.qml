import QtQuick 2.15

Item {
    property string pkgName: "VBMS Harmony16"
    property string pkgDescriptionMd: "README.md"
    property string pkgLisp: "harmony16.lisp"
    property string pkgQml: ""
    property bool pkgQmlIsFullscreen: false
    property string pkgOutput: "vbms_harmony16.vescpkg"

    // This function should return true when this package is compatible
    // with the connected vesc-based device
    function isCompatible (fwRxParams) {
        var hwName = fwRxParams.hw.toLowerCase();
        var fwName = fwRxParams.fwName.toLowerCase();

        // vesc, vesc bms or custom module
        // Note that VBMS16 is a custom module
        var hwType = fwRxParams.hwTypeStr().toLowerCase();		

        //console.log("HW Name: " + hwName)
        //console.log("FW Name: " + fwName)
        //console.log("HW Type: " + hwType)

        // The classic VESC BMS does not support packages at all
        if (hwType == "vesc bms") {
            return false
        }
        
        // VBMS16 is a custom module
        if (hwType != "custom module") {
            return false
        }

        var res = false
        if (hwName == "vbms16" && (fwName == "harmony" || fwName == "")) {
            res = true
        }

        return res
    }
}
