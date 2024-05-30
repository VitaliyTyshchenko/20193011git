package main

import (
        "bufio"
        "encoding/json"
        "fmt"
        "io/ioutil"
        "os"
        "strings"
)

func main() {
        reader := bufio.NewReader(os.Stdin)
        var variables []map[string]string
        var mysqlrootpassword, mysqlsyncusername, mysqlsyncuserpassword string
        var confirmation string

        // Ask for MySQL root password once
        fmt.Print("Enter MySQL root password: ")
        mysqlrootpassword, _ = reader.ReadString('\n')
        mysqlrootpassword = strings.TrimSpace(mysqlrootpassword)

        // Ask for MySQL sync user name once
        fmt.Print("Enter MySQL sync user name: ")
        mysqlsyncusername, _ = reader.ReadString('\n')
        mysqlsyncusername = strings.TrimSpace(mysqlsyncusername)

        // Ask for MySQL sync user password once
        fmt.Print("Enter MySQL sync user password: ")
        mysqlsyncuserpassword, _ = reader.ReadString('\n')
        mysqlsyncuserpassword = strings.TrimSpace(mysqlsyncuserpassword)

        for {
                // Ask for server IP address
                fmt.Print("Enter server IP address: ")
                ip, _ := reader.ReadString('\n')
                ip = strings.TrimSpace(ip)

                // Ask for server password
                fmt.Print("Enter server password: ")
                password, _ := reader.ReadString('\n')
                password = strings.TrimSpace(password)

                // Store the IP and password in a map
                node := map[string]string{
                        "IP":       ip,
                        "Password": password,
                }
                variables = append(variables, node)

                // Ask for confirmation
                fmt.Print("That is or not yet? (yes/no): ")
                confirmation, _ = reader.ReadString('\n')
                confirmation = strings.TrimSpace(confirmation)

                // Check if confirmation is 'yes'
                if strings.ToLower(confirmation) == "yes" {
                        // Create a final map to include MySQL root and sync user passwords
                        finalVariables := map[string]interface{}{
                                "mysqlrootpassword":    mysqlrootpassword,
                                "mysqlsyncusername":    mysqlsyncusername,
                                "mysqlsyncuserpassword": mysqlsyncuserpassword,
                                "nodes":                variables,
                        }

                        // Marshal the final map to JSON
                        jsonData, err := json.Marshal(finalVariables)
                        if err != nil {
                                fmt.Println("Error marshaling to JSON:", err)
                                return
                        }

                        // Print JSON data
                        fmt.Println("All variables provided in JSON format:")
                        fmt.Println(string(jsonData))

                        // Save JSON data to a file
                        err = saveToFile(jsonData)
                        if err != nil {
                                fmt.Println("Error saving JSON data to file:", err)
                                return
                        }
                        fmt.Println("JSON data saved to parameters.json")

                        // Copy template files and replace placeholders
                        if err := copyTemplate("templateforpakageintallation", "1server_%s_forpakageintallation", mysqlrootpassword, variables); err != nil {
                                fmt.Println("Error copying template file:", err)
                                return
                        }
                        fmt.Println("Template files copied for package installation")

                        // Copy template file for setting MySQL root password
                        if err := copyTemplate("templatesqlsettingrootpassword", "2sqlsettingrootpassword", mysqlrootpassword, nil); err != nil {
                                fmt.Println("Error copying template file:", err)
                                return
                        }
                        fmt.Println("Template file copied for MySQL root password setting")

                        // Copy template file for creating MySQL sync user
                        if err := createSyncUserFile("templatesqlcreatingsyncuser", "2sqlcreatingsyncuser", mysqlsyncusername, mysqlsyncuserpassword); err != nil {
                                fmt.Println("Error creating sync user file:", err)
                                return
                        }
                        fmt.Println("File created for MySQL sync user creation")

                        break
                } else {
                        fmt.Println("Please, provide server IP and password for the next node.")
                }
        }
}

// Function to save JSON data to a file
func saveToFile(data []byte) error {
        file, err := os.Create("parameters.json")
        if err != nil {
                return err
        }
        defer file.Close()

        _, err = file.Write(data)
        if err != nil {
                return err
        }

        return nil
}

// Function to copy template file and replace placeholders
func copyTemplate(templateName, outputName, mysqlrootpassword string, variables []map[string]string) error {
        // Read template file
        templateData, err := ioutil.ReadFile(templateName)
        if err != nil {
                return err
        }

        // If variables are provided, iterate over them and replace placeholders
        if variables != nil {
                for _, v := range variables {
                        template := string(templateData)
                        template = strings.ReplaceAll(template, "$IP", v["IP"])
                        template = strings.ReplaceAll(template, "$password", v["Password"])

                        // Create new file with appropriate name
                        fileName := fmt.Sprintf(outputName, v["IP"])
                        err := ioutil.WriteFile(fileName, []byte(template), 0644)
                        if err != nil {
                                return err
                        }
                }
        } else {
                // If variables are not provided, just replace $mysqlrootpassword and create the file
                template := string(templateData)
                template = strings.ReplaceAll(template, "$mysqlrootpassword", mysqlrootpassword)
                err := ioutil.WriteFile(outputName, []byte(template), 0644)
                if err != nil {
                        return err
                }
        }

        return nil
}

// Function to create sync user file and replace placeholders
func createSyncUserFile(templateName, outputName, mysqlsyncusername, mysqlsyncuserpassword string) error {
        // Read template file
        templateData, err := ioutil.ReadFile(templateName)
        if err != nil {
                return err
        }

        // Replace placeholders with actual values
        template := string(templateData)
        template = strings.ReplaceAll(template, "$mysqlsyncusername", mysqlsyncusername)
        template = strings.ReplaceAll(template, "$mysqlsyncuserpassword", mysqlsyncuserpassword)

        // Create new file
        err = ioutil.WriteFile(outputName, []byte(template), 0644)
        if err != nil {
                return err
        }

        return nil
}

