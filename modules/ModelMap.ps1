# ModelMap.ps1
# Raw camera id (often "Make Model") -> normalized folder name
# IMPORTANT: keys must be unique.

$script:ModelMap = @{

  # -----------------------------
  # Apple / iPhone / iPad
  # -----------------------------
  "Apple iPad 2"                                = "Apple iPad 2"

  "Apple iPhone 4"                              = "Apple iPhone 4"
  "Apple iPhone 5"                              = "Apple iPhone 5"
  "Apple iPhone 6"                              = "Apple iPhone 6"
  "Apple iPhone 6s"                             = "Apple iPhone 6s"
  "Apple iPhone 7"                              = "Apple iPhone 7"
  "Apple iPhone X"                              = "Apple iPhone X"
  "Apple iPhone XS Max"                         = "Apple iPhone XS Max"
  "Apple iPhone 12 Pro"                         = "Apple iPhone 12 Pro"
  "Apple iPhone 14 Pro"                         = "Apple iPhone 14 Pro"
  "Apple iPhone 14 Pro 24mm"                    = "Apple iPhone 14 Pro"
  "Apple iPhone 15 Pro Max"                     = "Apple iPhone 15 Pro Max"

  # Model-only variants
  "iPad 2"                                      = "Apple iPad 2"
    
  "iPhone 4"                                    = "Apple iPhone 4"
  "iPhone 5"                                    = "Apple iPhone 5"
  "iPhone 6"                                    = "Apple iPhone 6"
  "iPhone 6s"                                   = "Apple iPhone 6s"
  "iPhone 7"                                    = "Apple iPhone 7"
  "iPhone X"                                    = "Apple iPhone X"
  "iPhone XS Max"                               = "Apple iPhone XS Max"
  "iPhone 12 Pro"                               = "Apple iPhone 12 Pro"
  "iPhone 14 Pro"                               = "Apple iPhone 14 Pro"
  "iPhone 15 Pro Max"                           = "Apple iPhone 15 Pro Max"

  # -----------------------------
  # Google / LG / Android (normalize variants)
  # -----------------------------
  "Google Nexus 5"                              = "Google Nexus 5"
  "LGE Nexus 5"                                 = "Google Nexus 5"
  "LG Nexus 5"                                  = "Google Nexus 5"
  "Nexus 5"                                     = "Google Nexus 5"

  "Samsung Galaxy Nexus"                        = "Samsung Galaxy Nexus"
  "Galaxy Nexus"                                = "Samsung Galaxy Nexus"

  "SAMSUNG GT-I9505"                            = "Samsung Galaxy S4"
  "GT-I9505"                                    = "Samsung Galaxy S4"
  "SAMSUNG GT-I9505G"                           = "Samsung Galaxy S4"
  "GT-I9505G"                                   = "Samsung Galaxy S4"

  "ALCATEL ONE TOUCH 7041X"                     = "Alcatel OT 7041X"
  "TCT ALCATEL ONE TOUCH 7041X"                 = "Alcatel OT 7041X"
  "HTC One"                                     = "HTC One"

  # -----------------------------
  # Sony (ILCE + Cyber-shot)
  # -----------------------------
  "SONY ILCE-6000"                              = "Sony A6000"
  "ILCE-6000"                                   = "Sony A6000"
  "SONY ILCE-7M3"                               = "Sony A7 III"
  "ILCE-7M3"                                    = "Sony A7 III"
  "SONY ILCE-7M4"                               = "Sony A7 IV"
  "ILCE-7M4"                                    = "Sony A7 IV"
  "SONY ILCE-7RM5"                              = "Sony A7R V"
  "ILCE-7RM5"                                   = "Sony A7R V"

  "DSC-P100"                                    = "Sony Cyber-shot DSC-P100"
  "SONY DSC-P100"                               = "Sony Cyber-shot DSC-P100"
  "DSC-T70"                                     = "Sony Cyber-shot DSC-T70"
  "SONY DSC-T70"                                = "Sony Cyber-shot DSC-T70"
  "DSC-W5"                                      = "Sony Cyber-shot DSC-W5"
  "SONY DSC-W5"                                 = "Sony Cyber-shot DSC-W5"
  "DSC-W620"                                    = "Sony Cyber-shot DSC-W620"
  "SONY DSC-W620"                               = "Sony Cyber-shot DSC-W620"

  # -----------------------------
  # Fujifilm
  # -----------------------------
  "GFX 50R"                                     = "Fujifilm GFX 50R"
  "FUJIFILM GFX 50R"                            = "Fujifilm GFX 50R"

  "X100F"                                       = "Fujifilm X100F"
  "FUJIFILM X100F"                              = "Fujifilm X100F"

  "X100VI"                                      = "Fujifilm X100VI"
  "FUJIFILM X100VI"                             = "Fujifilm X100VI"

  "X-Pro1"                                      = "Fujifilm X-Pro1"
  "FUJIFILM X-Pro1"                             = "Fujifilm X-Pro1"

  "X-T3"                                        = "Fujifilm X-T3"
  "FUJIFILM X-T3"                               = "Fujifilm X-T3"

  "X-T30"                                       = "Fujifilm X-T30"
  "FUJIFILM X-T30"                              = "Fujifilm X-T30"

  "X-T5"                                        = "Fujifilm X-T5"
  "FUJIFILM X-T5"                               = "Fujifilm X-T5"

  # instax mini Evo (FI019)
  "FI019"                                       = "Fujifilm Instax Mini Evo"
  "FUJIFILM FI019"                              = "Fujifilm Instax Mini Evo"

  # -----------------------------
  # Nikon
  # -----------------------------
  "NIKON CORPORATION NIKON D3300"               = "Nikon D3300"
  "NIKON D3300"                                 = "Nikon D3300"
  "D3300"                                       = "Nikon D3300"

  "NIKON CORPORATION NIKON D750"                = "Nikon D750"

  "NIKON CORPORATION NIKON D610"                = "Nikon D610"
  "NIKON D610"                                  = "Nikon D610"
  "D610"                                        = "Nikon D610"

  "NIKON CORPORATION NIKON D800"                = "Nikon D800"
  "NIKON D800"                                  = "Nikon D800"
  "D800"                                        = "Nikon D800"

  "NIKON Z 5"                                   = "Nikon Z5"
  "NIKON Z5"                                    = "Nikon Z5"
  "Z 5"                                         = "Nikon Z5"
  "NIKON CORPORATION NIKON Z 5"                 = "Nikon Z5"

  "NIKON Z 6"                                   = "Nikon Z6"
  "NIKON Z6"                                    = "Nikon Z6"
  "Z 6"                                         = "Nikon Z6"
  "NIKON CORPORATION NIKON Z 6"                 = "Nikon Z6"

  "NIKON Z 7"                                   = "Nikon Z7"
  "NIKON Z7"                                    = "Nikon Z7"
  "Z 7"                                         = "Nikon Z7"
  "NIKON CORPORATION NIKON Z 7"                 = "Nikon Z7"

  # -----------------------------
  # Canon
  # -----------------------------
  "Canon EOS 100D"                              = "Canon 100D"
  "EOS 100D"                                    = "Canon 100D"

  "Canon EOS 760D"                              = "Canon 760D"
  "EOS 760D"                                    = "Canon 760D"

  "Canon EOS 1100D"                             = "Canon 1100D"
  "EOS 1100D"                                   = "Canon 1100D"

  "Canon EOS R6"                                = "Canon R6"
  "EOS R6"                                      = "Canon R6"

  "Canon EOS 7D"                                = "Canon 7D"
  "EOS 7D"                                      = "Canon 7D"

  "Canon EOS 5D Mark II"                        = "Canon 5D Mark II"
  "EOS 5D Mark II"                              = "Canon 5D Mark II"

  "Canon EOS 5D Mark IV"                        = "Canon 5D Mark IV"
  "EOS 5D Mark IV"                              = "Canon 5D Mark IV"

  "Canon EOS-1D Mark IV"                        = "Canon 1D Mark IV"
  "EOS-1D Mark IV"                              = "Canon 1D Mark IV"
  "EOS 1D Mark IV"                              = "Canon 1D Mark IV"

  "Canon PowerShot A450"                        = "Canon PowerShot A450"
  "PowerShot A450"                              = "Canon PowerShot A450"

  "Canon PowerShot A720 IS"                     = "Canon PowerShot A720 IS"
  "PowerShot A720 IS"                           = "Canon PowerShot A720 IS"

  "Sure Shot Max Date"                          = "Canon Sure Shot Max Date"

  "Canon A-1"                                   = "Canon A-1"

  # -----------------------------
  # Olympus
  # -----------------------------
  "E-520"                                       = "Olympus E-520"
  "OLYMPUS E-520"                               = "Olympus E-520"
  "OLYMPUS IMAGING CORP. E-520"                 = "Olympus E-520"

  "E-M1MarkII"                                  = "Olympus OM-D E-M1 Mark II"
  "OM-D E-M1 Mark II"                           = "Olympus OM-D E-M1 Mark II"
  "OLYMPUS CORPORATION E-M1MarkII"              = "Olympus OM-D E-M1 Mark II"

  # -----------------------------
  # Leica
  # -----------------------------
  "LEICA M (Typ 240)"                           = "Leica M (Typ 240)"
  "Leica Camera AG LEICA M (Typ 240)"           = "Leica M (Typ 240)"
  "Leica M6"                                    = "Leica M6"

  # -----------------------------
  # GoPro
  # -----------------------------
  "HERO5 Black"                                 = "GoPro HERO5 Black"

  # -----------------------------
  # HP
  # -----------------------------
  "HP PhotoSmart R707 (V01.00)"                 = "HP Photosmart R707"
  "Hewlett-Packard HP PhotoSmart R707 (V01.00)" = "HP Photosmart R707"
  "HP Photosmart R707"                          = "HP Photosmart R707"

  # -----------------------------
  # Odd identifiers seen
  # -----------------------------
  "Applied Graphics Technologies Digital Link"  = "UNKNOWN"
  "302"                                         = "UNKNOWN"
  "Hipstamatic 302"                             = "UNKNOWN"
  "SP500"                                       = "UNKNOWN"
  "FUJI PHOTO FILM CO., LTD. SP500"             = "UNKNOWN"
}
